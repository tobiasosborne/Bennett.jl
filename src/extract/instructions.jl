# ---- instruction conversion ----

# ---- Bennett-37mt (Bennett-hao Phase 1) memcpy helpers ----

"""
    _alloca_root_ref(val, depth=0) -> Union{Nothing, _LLVMRef}

Walk the producer chain from a pointer SSA value back to its underlying
`alloca` instruction. Returns the alloca's LLVM ref, or `nothing` if the
chain doesn't bottom out in an alloca (e.g. function parameter, global,
ptr-phi, ptr-select).

Recursion bound at depth 8 to defend against pathological IR (LLVM
doesn't usually nest GEPs > 2 in practice).

Used by `_handle_memcpy_arm` to (a) check both pointers are
alloca-backed and (b) detect the same-alloca case (memmove dressed as
memcpy).
"""
function _alloca_root_ref(val::LLVM.Value, depth::Int=0)::Union{Nothing, _LLVMRef}
    depth > 8 && return nothing
    val.ref == C_NULL && return nothing
    if LLVM.API.LLVMIsAAllocaInst(val.ref) != C_NULL
        return val.ref
    end
    if val isa LLVM.Instruction && LLVM.opcode(val) == LLVM.API.LLVMGetElementPtr
        gep_ops = LLVM.operands(val)
        length(gep_ops) >= 1 || return nothing
        return _alloca_root_ref(gep_ops[1], depth + 1)
    end
    return nothing
end

"""
    _struct_field_widths(st::LLVM.StructType, inst, ptr_cells::Bool) -> Vector{Int}

Bennett-6bu3: extract the per-field bit-width layout of a StructType aggregate
for `insertvalue`/`extractvalue`. Mirrors `_sret_struct_fields`
(src/extract/sret.jl) but returns ONLY the per-field WIDTHS (in field order),
since the aggregate slot model is contiguous (no padding) — the
insert/extract operate on logical field INDEX, not byte offset.

Field rules (CLAUDE.md §1 — every rejection is fail-loud, citing Bennett-6bu3):
  * IntegerType → `LLVM.width`, REQUIRING width ∈ {8,16,32,64}. This is the
    load-bearing guard that keeps `{i64,i1}` (`llvm.*.with.overflow` results,
    `cmpxchg` results) FAILING LOUD — i1 is rejected.
  * PointerType → 64, but ONLY under `ptr_cells` (a pointer is one Int64 VM
    cell, ADR 0018 §A). Without ptr_cells a pointer field fails loud.
  * float / nested-struct / vector / array fields, packed structs, and empty
    structs are all rejected loud.

NOTE: pointer-field widths are computed HERE (constant 64), NOT routed through
`_iwidth`/`_type_width` — those have no PointerType arm and would error.
"""
function _struct_field_widths(st::LLVM.StructType, inst::LLVM.Instruction,
                              ptr_cells::Bool)::Vector{Int}
    LLVM.ispacked(st) && _ir_error(inst,
        "insertvalue/extractvalue on a PACKED StructType $(string(st)) is not " *
        "supported; only unpacked structs of fixed-width integer ({8,16,32,64}) " *
        "or (under ptr_cells) pointer fields are. (Bennett-6bu3)")
    elem_tys = LLVM.elements(st)
    isempty(elem_tys) && _ir_error(inst,
        "insertvalue/extractvalue on an EMPTY StructType $(string(st)) is not " *
        "supported; the aggregate has no fields. (Bennett-6bu3)")
    widths = Int[]
    for (k, fty) in enumerate(elem_tys)
        if fty isa LLVM.IntegerType
            w = LLVM.width(fty)
            w ∈ (8, 16, 32, 64) || _ir_error(inst,
                "StructType field $(k-1) of $(string(st)) has integer width $w " *
                "not in {8,16,32,64}; the bits-struct slot model only supports " *
                "fixed-width integer fields (this REJECTS i1 — `{i64,i1}` " *
                "overflow/cmpxchg structs are out of scope). (Bennett-6bu3)")
            push!(widths, Int(w))
        elseif fty isa LLVM.PointerType
            ptr_cells || _ir_error(inst,
                "StructType field $(k-1) of $(string(st)) is a pointer field, " *
                "which requires ptr_cells=true (a pointer is one Int64 VM cell, " *
                "ADR 0018 §A); on the circuit path pointer fields are not " *
                "supported. (Bennett-6bu3)")
            push!(widths, 64)
        else
            _ir_error(inst,
                "StructType field $(k-1) of $(string(st)) has unsupported type " *
                "$(string(fty)); only fixed-width integer ({8,16,32,64}) or " *
                "(under ptr_cells) pointer fields are supported — float, " *
                "nested-struct, vector, and array fields are rejected. " *
                "(Bennett-6bu3)")
        end
    end
    return widths
end

"""
    _alloca_reservation(inst, names, ptr_cells) -> Union{Nothing, Tuple{Int, IROperand}}

Bennett-p06b: the SINGLE SOURCE OF TRUTH for what an `alloca` actually reserves.
Returns exactly the `(elem_width, n_elems)` pair the alloca arm passes to
`IRAlloca`, or `nothing` when the allocated type is one the arm SILENTLY SKIPS
(a StructType, a nested ArrayType, a float, a PointerType with the gate off).

Both the alloca arm below AND `_p06b_cell_ptr_target_kind` call this. That is
the point: an earlier revision had p06b MIRROR the arm's logic instead of
sharing it, and the mirror drifted immediately — it read the ArrayType count
operand that the arm DISCARDS, so `alloca [1 x i64], i32 4` certified 4 cells
while the arm reserved 1, and a 2-field aggregate store clobbered the next
allocation (hostile review round 2, defect N1, executed witness
`scratchpad/h1_e2e.jl`: EXPECTED 999, ACTUAL 42). A mirrored predicate is a
latent miscompile with a docstring; a shared one cannot drift.

NOTE — the arm's ArrayType branch genuinely UNDER-RESERVES for
`alloca [K x iM], i32 N`: it reserves K cells and ignores N. That is a
pre-existing bug in the arm, NOT fixed here (fixing it would change gate-off
behaviour); it is filed as **Bennett-uiqq** (P2). This helper reports what the
arm ACTUALLY reserves, so p06b stays sound in the meantime — and p06b
additionally refuses `N != 1` outright rather than trusting the under-reservation.
"""
function _alloca_reservation(inst::LLVM.Instruction,
                             names::Dict{_LLVMRef, Symbol},
                             ptr_cells::Bool)
    elem_ty = LLVM.LLVMType(LLVM.API.LLVMGetAllocatedType(inst.ref))
    ops = LLVM.operands(inst)
    if elem_ty isa LLVM.ArrayType
        inner = LLVM.eltype(elem_ty)
        inner isa LLVM.IntegerType || return nothing
        # The count operand is DELIBERATELY not consulted — that is what the
        # arm does (Bennett-uiqq tracks the under-reservation).
        return (Int(LLVM.width(inner)), iconst(Int(LLVM.length(elem_ty))))
    end
    n_elems_op = if !isempty(ops) && ops[1] isa LLVM.ConstantInt
        iconst(_const_int_as_int(ops[1]))
    elseif !isempty(ops) && haskey(names, ops[1].ref)
        ssa(names[ops[1].ref])
    else
        iconst(1)
    end
    if ptr_cells && elem_ty isa LLVM.PointerType
        return (64, n_elems_op)
    elseif elem_ty isa LLVM.IntegerType
        return (Int(LLVM.width(elem_ty)), n_elems_op)
    end
    return nothing
end

# ============================================================================
# Bennett-bvmd / CW-D4 (xkl wall 8) — ROOT SCALE, the bytes-per-cell ratio
# ============================================================================
#
# BennettVM is CELL-addressed: one `Int64` per cell, a pointer IS a cell index,
# and `IRPtrOffset(dest, base, offset_bytes, elem_width)` lowers to
#
#     Define(dest, base, :add, offset_bytes ÷ (elem_width ÷ 8))
#
# (`BennettVM/src/ir/ingest_body.jl:534`). So `elem_width` is NOT a type width in
# the cell model — it is exactly the object's BYTES-PER-CELL SCALE. An object's
# cell map is therefore fixed by two numbers: the scale its addresses use, and
# the number of cells its allocation reserved. Both are already determined, per
# allocation shape, by BennettVM code that SHIPS TODAY:
#
#   | root shape                   | scale | cap      | authority (verified)      |
#   |------------------------------|-------|----------|---------------------------|
#   | `IRAlloca(d, ew, n)`         | ew÷8  | n        | `_lower_alloca!` reserves |
#   |                              |       |          | `n` cells; its docstring  |
#   |                              |       |          | states "`elem_width` (in  |
#   |                              |       |          | bits) does NOT enter the  |
#   |                              |       |          | address" (ingest_body.jl  |
#   |                              |       |          | :581-586)                 |
#   | `julia.gc_alloc_obj(_,nb,_)` | **1** | nb       | `_alloc_cells(::Intrinsic |
#   |                              |       |          | GCAlloc) = _byte_cells(nb)|
#   |                              |       |          | ` (intrinsics.jl:256-257) |
#   | `malloc`/`calloc`/`realloc`  | **8** | nb÷8     | `_alloc_cells(::Intrinsic |
#   |                              |       |          | Malloc) = _cell_count(nb)`|
#   |                              |       |          | (intrinsics.jl:246)       |
#   | param / global / phi / load  | UNKNOWN          | no reservation exists IN  |
#   |                              |       |          | THIS FUNCTION             |
#
#   **(SC) — the scale-coherence invariant.** For every pointer root `R` whose
#   scale is KNOWN, every `IRPtrOffset` / `IRVarGEP` derived from `R` must carry
#   `elem_width == 8 · scale(R)`.
#
# (SC) is NOT an invented tier tag. The extractor does not DECIDE a granularity;
# it READS the ratio off the same allocator table BVM's `_alloc_cells`
# implements — the same "shared, never mirrored" discipline `_alloca_reservation`
# already enforces between the alloca arm and `_p06b_alloca_cells` (whose mirror
# drifted and produced a silent clobber, hostile review N1).
#
# (SC) subsumes the whole granularity discipline as ONE sentence: wall 8's
# byte-stamped admission, the CW-D4 class-D split (`gep i8 %obj, 8` → cell +8 vs
# `gep {ptr,ptr} %obj, 0, 1` → cell +1, SIX such loads on one object in the push!
# ROOT), `Bennett-z2ia` (a byte GEP past a word-tier alloca reservation),
# `Bennett-4y0d` (a K≥2 arena memcpy), and `bennettvm-jb6w` (the clang
# register-coercion spill) are all instances of it.
#
# ENFORCEMENT IS TWO-LAYERED, and the layers are deliberately different in kind:
#
#   1. A SHARED STAMP at the sites that CHOOSE an `elem_width` (the D4 two-index
#      struct-GEP arm, the p06b decomposition's emission and its (P5) scan, the
#      vbv9 arena-memcpy dst). Because checker and emitter call ONE function,
#      their agreement is a lemma rather than a review obligation.
#   2. A STREAM CHECK (`_check_scale_coherence!`, module_walk.jl) over the
#      EMITTED node list. (SC) is a property of the emitted stream, so ONE check
#      covers all NINE `IRPtrOffset` construction sites — including the six
#      (`heap.jl` ×2, `vectors.jl`, `instructions.jl`'s memcpy/memset/lane arms)
#      that this arc does not touch and nobody has audited — without a nine-site
#      patch. It runs AFTER every instruction in the function has converted, so
#      any in-conversion fail-loud still wins and no existing message territory
#      moves.
#
# Layer 1 alone drifts; layer 2 alone cannot pick the right stamp. Both.
#
# GATED ON `ptr_cells`. MEASURED, not reasoned: on the circuit path `elem_width`
# is inert (the gate backend ignores the field — see `test_vz5n`'s own comment),
# and an ungated guard fires on green circuit-path programs.

# Depth bound shared with `_alloca_root_ref` / `_gc_alloc_root_ref` /
# `_param_ptr_root_ref` — this walker introduces no new recursion SHAPE, only a
# different bottom-out predicate (LLVM does not nest GEPs > 2 in practice).
const _BVMD_ROOT_DEPTH = 8

"""
    _root_scale(val, names, ptr_cells, depth=0)
        -> Union{Nothing, Tuple{Int, Int, String}}

Bennett-bvmd: the scale (BYTES PER CELL) and capacity (IN THOSE CELLS) of the
allocation `val` is derived from, or `nothing` when no allocation root exists in
this function (a pointer parameter, a global, a `phi`/`select` pointer, a value
loaded from memory, `julia.gc_loaded`, …).

Returns `(scale_bytes, cap_cells, description)`. `cap_cells == -1` means the
reservation is not a compile-time constant — the SCALE is still known and (SC)
still applies; only the capacity half is unprovable.

Walks the constant-GEP producer chain exactly as `_gc_alloc_root_ref` does
(`gep_ops[1]` base step, depth-8 bound). Every row of the table above is read
from a BennettVM authority, never invented here; the `alloca` row goes through
`_alloca_reservation`, the SINGLE SOURCE OF TRUTH the alloca arm itself uses, so
this walker cannot drift from what is actually reserved.
"""
# COUPLING — SECOND CONSUMER (Bennett-57hd / ADR 0017 §4b). `_57hd_clobbered`
# takes a SAME-ROOT byte-range non-overlap decision ONLY when this returns the
# BYTE TIER (`scale == 1`), because a byte-range disjointness is a claim about
# VM CELLS and only the byte tier makes byte offsets BE cell offsets. That is
# `bennettvm-jb6w` pre-empted rather than amplified. A scale that stops being 1
# turns the judgement into a clobber ⇒ REJECT ⇒ the existing loud wall, i.e.
# drift here degrades §4b conservatively. Pinned by gates (G)/(G2) of
# `test_57hd_value_identity.jl`.
function _root_scale(val::LLVM.Value, names::Dict{_LLVMRef, Symbol},
                     ptr_cells::Bool, depth::Int=0)
    depth > _BVMD_ROOT_DEPTH && return nothing
    val.ref == C_NULL && return nothing
    val isa LLVM.Instruction || return nothing
    opc = LLVM.opcode(val)
    if opc == LLVM.API.LLVMAlloca
        r = _alloca_reservation(val, names, ptr_cells)
        # An alloca whose allocated type the arm SILENTLY SKIPS reserves
        # nothing, so there is no scale to be coherent with.
        r === nothing && return nothing
        ew, nop = r
        (ew >= 8 && ew % 8 == 0) || return nothing
        cap = nop isa ConstOperand ? Int(nop.value) : -1
        return (ew ÷ 8, cap,
                "an `alloca` reservation of " *
                (cap < 0 ? "a RUNTIME number of" : string(cap)) * " cell(s)")
    elseif opc == LLVM.API.LLVMCall
        cops = LLVM.operands(val)
        n = length(cops)
        n >= 1 || return nothing
        cn = try
            LLVM.name(cops[n])
        catch e
            e isa InterruptException && rethrow()
            return nothing
        end
        if cn == "julia.gc_alloc_obj"
            # `_alloc_cells(::IntrinsicGCAlloc) = _byte_cells(nbytes)`: ONE cell
            # per BYTE address, with a 64-bit value living in exactly one cell at
            # its base byte address (cells +1…+7 are never named). The convention
            # already shipped by bennettvm-416r.13, 9n3y and vbv9.
            nb = (n >= 3 && cops[2] isa LLVM.ConstantInt) ?
                 Int(_const_int_as_int(cops[2])) : -1
            return (1, nb,
                    "a `julia.gc_alloc_obj` BYTE-cell reservation of " *
                    (nb < 0 ? "a RUNTIME number of" : string(nb)) * " cell(s)")
        elseif cn in _M4_C_ALLOCATOR_NAMES
            b = _p06b_call_bytes(val)
            return (8, b < 0 ? -1 : b ÷ 8,
                    "a `$(cn)` WORD-cell reservation of " *
                    (b < 0 ? "a RUNTIME number of" : string(b ÷ 8)) * " cell(s)")
        end
        return nothing
    elseif opc == LLVM.API.LLVMGetElementPtr
        gops = LLVM.operands(val)
        length(gops) >= 1 || return nothing
        return _root_scale(gops[1], names, ptr_cells, depth + 1)
    end
    return nothing
end

"""
    _cell_elem_width_struct_gep(base, src_type, names, ptr_cells) -> 8 | 64

Bennett-bvmd: the SHARED stamp for the BVM ADR 0020 D4 two-index struct GEP and
for every predicate that must agree with it (p06b's (P5) scan and its
decomposition emission). Provenance where it is PROVEN, the shipped
`_is_genericmemory_header_struct` TYPE predicate where the root is unknown.

**The union is load-bearing in BOTH directions, and the ORDER matters.**

  * Provenance FIRST. A `malloc(16)` object addressed by
    `gep {i64,ptr}, ptr %p, 0, 1` is a literal `{i64,ptr}` — the type predicate
    would stamp 8 and send the field to cell +8, which is OUTSIDE the 2-cell
    word reservation `_alloc_cells(::IntrinsicMalloc)` makes. The reservation,
    not the type spelling, is what fixes the cell map, so where a reservation is
    proven it WINS.
  * Type predicate as the FALLBACK, never as a replacement. The
    bennettvm-416r.13 singleton headers are `load ptr, ptr @"jl_global#N"` — a
    GLOBAL, with NO allocation root in this function, so provenance is silent
    there. A provenance-ONLY rule would silently demote those headers to word
    granularity and break the shipped `length@byte-cell 0 / data-ptr@byte-cell 8`
    layout: a silent miscompile. `test_bvmd_root_scale.jl` (C) is that control.

The C tier is byte-identical BY CONSTRUCTION: for `malloc`/`alloca` the scale is
8, so `8·scale == 64` — precisely the stamp those arms already emit.
"""
function _cell_elem_width_struct_gep(base::LLVM.Value, src_type,
                                     names::Dict{_LLVMRef, Symbol},
                                     ptr_cells::Bool)::Int
    rs = _root_scale(base, names, ptr_cells)
    rs === nothing && return _is_genericmemory_header_struct(src_type) ? 8 : 64
    return 8 * rs[1]
end

"""
    _const_gep_stamp(gepval) -> Union{Nothing, Int}

Bennett-bvmd: the `elem_width` the SINGLE-INDEX constant GEP arm emits for
`gepval`, computed by the arm's own rule (source element bit width for an
integer source type, else the legacy raw-index unit of 8 — Bennett-vz5n / U12,
Bennett-qal5 / U16). Used by p06b's (P5) so the scan compares against what is
ACTUALLY emitted rather than re-deriving a granularity.

Returns `nothing` for a shape the arm does not emit an `IRPtrOffset` for.
"""
# The allocation-root REF of a pointer value (the const-GEP chain's bottom),
# used only to test membership of the module walk's `suppressed` set. Mirrors
# `_root_scale`'s recursion; kept separate so `_root_scale`'s signature stays
# the shared one the stamp sites call.
function _bvmd_root_ref(val::LLVM.Value, depth::Int=0)::Union{Nothing,_LLVMRef}
    depth > _BVMD_ROOT_DEPTH && return nothing
    val.ref == C_NULL && return nothing
    val isa LLVM.Instruction || return nothing
    if LLVM.opcode(val) == LLVM.API.LLVMGetElementPtr
        gops = LLVM.operands(val)
        length(gops) >= 1 || return nothing
        return _bvmd_root_ref(gops[1], depth + 1)
    end
    return val.ref
end

"""
    _check_scale_coherence!(blocks, func, names, ptr_cells, suppressed)

Bennett-bvmd — the **(SC) STREAM CHECK**. Enforces, over the EMITTED node list
of one function, that every `IRPtrOffset` / `IRVarGEP` whose base traces to an
allocation root of PROVABLE scale carries `elem_width == 8 · scale(root)`.

WHY A STREAM CHECK AND NOT NINE SITE PATCHES. `IRPtrOffset` is constructed at
NINE places (`instructions.jl` ×6, `heap.jl` ×2, `vectors.jl`), six of which no
one has audited for cell granularity. (SC) is a property of the emitted stream,
so ONE check covers all nine — including sites this arc deliberately does not
touch — and it keeps covering them when a tenth is added. That is why the guard,
not the re-stamp, is the drift-proof half of Bennett-bvmd.

WHY IT RUNS AT THE END. Every in-conversion fail-loud (`_ir_error`) is raised
while an instruction is being converted, i.e. STRICTLY BEFORE this runs. So no
existing message territory moves: a program that walls at (P1)/(P4b)/(P5)/lgzx/
37mt still walls there, with the same message. This check can only add a NEW
loud failure, and only for a program that previously extracted SILENTLY WRONG.

ADMISSION BEFORE REFUSAL — the `Bennett-z2ia` half. A LOUD REFUSAL ALONE IS NOT
SHIPPABLE, and that is a measured fact, not a preference: Julia codegen
byte-addresses its own stack frames routinely (`alloca [N x i64]` + `gep i8 …,
8k`), and at least three live witnesses do it — the push! ROOT's closure env,
`test_qmv7`'s `gc_loaded` fixtures, and `test_40ys`'s boxed `Pair40ys`, the last
of which EXTRACTS AND RUNS AND REVERSES ON THE VM TODAY
(`../BennettVM.jl/test/test_40ys_closure_callee_vm.jl`). Refusing them would
trade a latent hole for a functional regression.

So before enforcing, this pass RE-STAMPS the accesses it can — see the ADMISSION
block below for the preconditions and for why re-stamping the ACCESSES rather
than widening the RESERVATION is the shipped choice (measured: the reservation
rewrite escapes into the circuit backend and breaks it, the access re-stamp is
provably invisible there because `lower_ptr_offset!` never reads
`IRPtrOffset.elem_width`).

A GENUINELY MIXED object — one addressed at two granularities — is re-stamped by
nothing and REFUSED loudly. That is the case `bennettvm-jb6w` is about, and it is
the case that was silently miscompiling.

WHAT IT DOES NOT COVER (prose-vs-predicate — stated, not closed):
  * a root reached only through memory (a pointer stored and re-loaded), a
    `phi`/`select` pointer, or a `julia.gc_loaded` launder: the walk yields
    `nothing` and the check is SILENT. Same residual class as
    `_p06b_alias_group`'s same-slot closure.
  * CAPACITY. The message REPORTS the reservation size as context, but the
    predicate tested is scale agreement ALONE. Refusing out-of-reservation
    accesses in the stream is a strictly larger change (it would fire on the
    Bennett-uiqq alloca under-reservation, among others) and is left to p06b's
    (P4c) for stores and to `bennettvm-pdqx` for the VM.
  * a CALLEE that receives a byte-tier cell and word-addresses it. Out of model;
    the closed-world check owns it, as it already does for `bennettvm-jb6w`.

GATED ON `ptr_cells`. MEASURED: on the circuit path `IRPtrOffset.elem_width` is
inert and an ungated guard fires on green circuit-path programs.

**The gate is NOT what protects the circuit backend** — an earlier revision of
this docstring claimed it was, and that was FALSE: `ptr_cells=true` + `lower()`
is a live combination in this suite (`test_59zi`, `test_lf14`), so anything this
pass writes into the ParsedIR reaches the gate path too. What actually protects
it is the CHOICE OF EDIT: `lower_ptr_offset!` (`src/lowering/aggregate.jl:195-280`)
slices by `offset_bytes * 8` and bumps the `PtrOrigin` index by
`div(offset_bytes * 8, ew)` with `ew` taken from `alloca_info` — it never reads
`IRPtrOffset.elem_width` at all. Re-stamping that field is therefore a no-op
there, while rewriting the `IRAlloca` was not (measured: it throws in
`_lower_store_via_shadow!`, store width 64 vs alloca elem_width 8).
"""
function _check_scale_coherence!(blocks::Vector{IRBasicBlock},
                                 func::LLVM.Function,
                                 names::Dict{_LLVMRef, Symbol},
                                 ptr_cells::Bool,
                                 suppressed::Set{_LLVMRef})
    ptr_cells || return nothing
    # Reverse the naming table: an emitted node's base is an SSA SYMBOL, and the
    # root walk needs the LLVM value it was registered from.
    by_name = Dict{Symbol, LLVM.Value}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        nm = get(names, inst.ref, nothing)
        nm === nothing && continue
        # TIE-BREAK: first registration wins. The naming pass is NOT injective —
        # the 416r.13 singleton arm at `:5669` DELIBERATELY aliases a `load ptr,
        # ptr @"jl_global#N"` dest to the global's own name, so several loads can
        # share one symbol. Every such collider is a ROOTLESS load (a global has
        # no allocation root in this function), so `_root_scale` returns `nothing`
        # for all of them and the arbitrary pick is harmless FOR THAT CLASS. It
        # would not be harmless for a collider with differing roots; no such
        # aliasing exists today.
        haskey(by_name, nm) || (by_name[nm] = inst)
    end

    # ---- resolve every offset node to its allocation root, once ----
    # `resolved[i] = (node, blk, idx, root_ref, scale, cap, what, raw)`.
    # `raw` marks the RAW-INDEX node class: a 2-op GEP whose source element type
    # is NOT an integer emits `IRPtrOffset(dest, base, RAW_INDEX, 8)` — the
    # legacy U16 branch (`instructions.jl:4810-4815`), where `offset_bytes` is
    # NOT a byte offset at all and `8` is a placeholder unit, not a granularity.
    # (SC) is UNEVALUABLE on such a node: comparing cells needs a byte offset.
    # They are therefore excluded from both the re-stamp trigger and the
    # enforcement rather than acted on with a meaningless number. The underlying
    # raw-index blind spot is pre-existing and separately filed.
    resolved = Tuple{IRInst, IRBasicBlock, Int, Union{Nothing,_LLVMRef},
                     Int, Int, String, Bool}[]
    for blk in blocks, (idx, node) in enumerate(blk.instructions)
        (node isa IRPtrOffset || node isa IRVarGEP) || continue
        base_op = node.base
        base_op isa SSAOperand || continue
        bv = get(by_name, base_op.name, nothing)
        bv === nothing && continue
        rroot = _bvmd_root_ref(bv)
        # A SUPPRESSED root (an sret / consumed-sret box alloca) reserves
        # nothing — `module_walk.jl` emits no `IRAlloca` for it — so there is no
        # cell map for these nodes to be coherent with. Same exemption p06b's
        # (P4b') makes.
        (rroot !== nothing && rroot in suppressed) && continue
        rs = _root_scale(bv, names, ptr_cells)
        rs === nothing && continue
        raw = let gv = get(by_name, node.dest, nothing)
            gv !== nothing && gv isa LLVM.Instruction &&
            LLVM.opcode(gv) == LLVM.API.LLVMGetElementPtr &&
            length(LLVM.operands(gv)) == 2 &&
            !(LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(gv.ref))
              isa LLVM.IntegerType)
        end
        push!(resolved, (node, blk, idx, rroot, rs[1], rs[2], rs[3], raw))
    end

    # ---- ADMISSION: use-directed BYTE-NORMALISATION of the RESERVATION ----
    #
    # The object is byte-addressed by Julia codegen but word-RESERVED by the
    # alloca arm. Two ways to make one cell map out of that. **Both were built
    # and measured; the reservation widening is the one that is SOUND.**
    #
    #   (a) widen the RESERVATION (`IRAlloca(d,64,n) → (d,8,8n)`). SHIPPED.
    #       Expressible with ZERO BennettVM change (`_lower_alloca!` reserves
    #       `n` cells and its docstring states `elem_width` "does NOT enter the
    #       address"); WIRE-COUNT-NEUTRAL on the gate path
    #       (`_lower_alloca_const_n!` allocates `elem_width * n` BITS and
    #       `64·n == 8·8n`); STORAGE-NEUTRAL (`IState.memory` is a sparse Dict).
    #   (b) re-stamp the ACCESSES to the root's own scale
    #       (`IRPtrOffset(_,_,off,8) → (_,_,off,8·scale)`). **REJECTED — it is
    #       NOT CLOSED UNDER FUNCTION BOUNDARIES**, and that is measured, not
    #       argued. This pass runs PER FUNCTION. In the caller, the box's byte
    #       GEPs get re-stamped to word cells; in the CALLEE the very same
    #       object arrives as a pointer PARAMETER, whose scale is UNKNOWN, so
    #       its byte GEPs are left alone. Caller writes cell +1, callee reads
    #       cell +8. Executed witness: `Bennett-40ys`'s boxed `Pair40ys`
    #       caller→callee set returned **30 where the oracle says 42**
    #       (`../BennettVM.jl/test/test_40ys_closure_callee_vm.jl` gate (g), 28
    #       assertions). (a) has no such hazard BY CONSTRUCTION: it changes the
    #       reservation SIZE, never the addressing, so every function that
    #       byte-addresses the object continues to agree with every other.
    #
    # The price of (a) is real and is NOT hidden: a byte-normalised `IRAlloca`
    # also reaches the CIRCUIT backend (`ptr_cells` is an EXTRACTION flag, and
    # `ptr_cells=true` + `lower()` is live — test_59zi, test_lf14), where the
    # shadow-tape store/load path requires `store width == alloca elem_width`.
    # `lower()` therefore REFUSES such a ParsedIR loudly and by name — see
    # `_bvmd_reject_normalised_alloca!` in `src/lowering/driver.jl`.
    #
    # The rewrite is USE-DIRECTED, never blanket. A blanket byte-normalisation
    # is unsound: `alloca i32, i32 8` + `gep i32 …, 3` is coherent TODAY at
    # scale 4 and `alloca i64, i32 4` + `gep i64 …, 2` at scale 8 — both would
    # BECOME violations under a scale of 1. Preconditions: every node off the
    # root is byte-stamped and non-raw-index, and at least one genuinely
    # disagrees. A MIXED object is normalised by nothing and REFUSED loudly —
    # `bennettvm-jb6w`'s hazard, made loud. `elem_width != 64` allocas (the
    # typed-array tier) and RUNTIME-count allocas are never touched; dynamic-`n`
    # would need an emitted `IRBinOp(:mul, n, 8)` and changes `DynAlloca` arity
    # in BennettVM, so it stays filed on `Bennett-z2ia`.
    all_byte = Dict{_LLVMRef, Bool}()
    needs = Dict{_LLVMRef, Bool}()
    for (node, _blk, _idx, rroot, scale, _cap, _what, raw) in resolved
        rroot === nothing && continue
        raw && continue                      # (SC) is unevaluable — see above
        ew = node.elem_width
        all_byte[rroot] = get(all_byte, rroot, true) && ew == 8
        if node isa IRPtrOffset && ew != 8 * scale && ew >= 8 && ew % 8 == 0 &&
           node.offset_bytes ÷ (ew ÷ 8) != node.offset_bytes ÷ scale
            needs[rroot] = true
        end
    end
    normalised = Set{_LLVMRef}()
    for (rroot, ab) in all_byte
        (ab && get(needs, rroot, false)) || continue
        rv = LLVM.Value(rroot)
        LLVM.opcode(rv) == LLVM.API.LLVMAlloca || continue
        r = _alloca_reservation(rv, names, ptr_cells)
        r === nothing && continue
        ew_a, nop = r
        (ew_a == 64 && nop isa ConstOperand) || continue
        dname = get(names, rroot, nothing)
        dname === nothing && continue
        n_new = 8 * Int(nop.value)
        hit = false
        for blk in blocks, (i, nd) in enumerate(blk.instructions)
            nd isa IRAlloca || continue
            nd.dest === dname || continue
            blk.instructions[i] = IRAlloca(dname, 8, iconst(n_new))
            hit = true
        end
        hit && push!(normalised, rroot)
    end

    # ---- ENFORCEMENT ----
    for (node, _blk, _idx, rroot, scale0, cap0, what0, raw) in resolved
        raw && continue                      # (SC) is unevaluable — see above
        norm = rroot !== nothing && rroot in normalised
        scale = norm ? 1 : scale0
        cap = norm ? (cap0 < 0 ? -1 : 8 * cap0) : cap0
        what = norm ? "an `alloca` reservation BYTE-NORMALISED by Bennett-bvmd " *
                      "to $(cap) cell(s)" : what0
        ew = node.elem_width
        dest = node.dest
        base_op = node.base
        want = 8 * scale
        ew == want && continue
        (ew >= 8 && ew % 8 == 0) || continue    # BVM's own divisibility guard
        # An `IRVarGEP` carries a RUNTIME index, so there is no constant cell to
        # compare and the vacuity exemption below MUST NOT apply to it — the
        # predicate is bare stamp equality. (Guarding this with `node isa
        # IRPtrOffset` is the whole fix: the previous revision set both cells to
        # -1 for an IRVarGEP, so the exemption swallowed EVERY variable-index
        # node and the arm was dead code — a `gep i64, ptr %obj, i64 %i` off a
        # byte-tier `gc_alloc` box extracted silently at elem_width 64 and BVM
        # lowered it at a stride of one cell: an 8x misaddress.)
        cell_emitted = node isa IRPtrOffset ? node.offset_bytes ÷ (ew ÷ 8) : -1
        cell_meant = node isa IRPtrOffset ? node.offset_bytes ÷ scale : -2
        # VACUOUS DISAGREEMENT. A node whose own step lands on the SAME cell
        # under both stamps addresses nothing wrongly — canonically `gep i8
        # %obj, 0`, which Julia codegen emits constantly (a GC-roots slot
        # address, a `%".roots.#self#"` re-base) and which maps to cell +0 under
        # EVERY stamp. MEASURED: without this, `test_40ys` (G)/(H)/(K) go red on
        # a byte offset of ZERO.
        #
        # This is NOT p06b's dropped D2 index-0 carve-out re-introduced. D2's
        # hazard was that the carved-out GEP's RESULT becomes a fresh
        # byte-granular base whose own deeper offsets were never re-scanned (the
        # scan is one level deep). This check walks the FULL const-GEP chain to
        # the allocation root at EVERY node, so `gep i8 %g0, 8` off such a base
        # is checked against the root independently and still fires. The
        # carve-out is safe here precisely because the closure is not one-deep.
        (node isa IRPtrOffset && cell_emitted == cell_meant) && continue
        where_ = node isa IRVarGEP ? "IRVarGEP" : "IRPtrOffset"
        detail = node isa IRVarGEP ?
            "The index is a RUNTIME value, so there is no constant cell to " *
            "compare: BennettVM strides this node by ONE CELL per index unit, " *
            "which is faithful only when the stamp IS the root's scale. " :
            "BennettVM recovers the cell as `offset_bytes ÷ (elem_width ÷ 8)`, " *
            "so byte offset $(node.offset_bytes) is addressed as cell " *
            "base+$(cell_emitted) where the reservation means cell " *
            "base+$(cell_meant) — two cell maps for one object" *
            (cap >= 0 && cell_emitted >= cap ?
             ", and cell base+$(cell_emitted) lies OUTSIDE the $(cap)-cell " *
             "reservation (a silent adjacent-allocation clobber, which " *
             "`bennettvm-pdqx` does NOT detect — it rejects only accesses " *
             "outside ALL live reservations)" : "") * ". "
        error("ir_extract.jl: SCALE-COHERENCE violation in " *
              "@$(LLVM.name(func)): the emitted $(where_) `$(dest)` off base " *
              "`$(base_op.name)` carries elem_width=$(ew), but its allocation " *
              "ROOT is $(what), i.e. cells of $(scale) byte(s), so every " *
              "offset derived from that root must be stamped " *
              "elem_width=$(want)$(norm ? " (the reservation was ALREADY " *
              "byte-normalised, so this object is addressed at TWO " *
              "granularities and no single reservation can serve both)" : ""). " *
              detail *
              "(Bennett-bvmd, predicate `_root_scale` / " *
              "`_check_scale_coherence!`.) The use-directed BYTE-NORMALISATION " *
              "that admits an all-byte-addressed word-tier `alloca` did NOT " *
              "apply here: it requires EVERY emitted offset off the root to be " *
              "byte-stamped, and a static 64-bit reservation. Failing that " *
              "means this object is addressed at TWO granularities and no " *
              "single reservation can serve both — the `bennettvm-jb6w` " *
              "hazard, made loud. Spell every access at ONE granularity. " *
              "(A dynamic-count `alloca` is also never normalised; that case " *
              "stays filed on Bennett-z2ia.)")
    end
    return nothing
end

function _const_gep_stamp(gepval::LLVM.Value)::Union{Nothing,Int}
    (gepval isa LLVM.Instruction &&
     LLVM.opcode(gepval) == LLVM.API.LLVMGetElementPtr) || return nothing
    ops = LLVM.operands(gepval)
    length(ops) == 2 || return nothing
    sty = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(gepval.ref))
    return sty isa LLVM.IntegerType ? Int(LLVM.width(sty)) : 8
end

# ============================================================================
# Bennett-p06b / CW-D — WHOLE-AGGREGATE `store` DECOMPOSITION (xkl wall 6)
# ============================================================================
#
#   store { ptr, ptr } %memory_ref, ptr %1     ; `_growend!` %L93 — THE WALL
#
# Under `ptr_cells` this decomposes into, for each field k of the StructType,
#
#   IRExtractValue(fk, <agg>, k, 0, N, field_widths)   ; the 6bu3 arm's shape
#   IRPtrOffset(ak, <p>, LLVMOffsetOfElement(S,k), 64) ; the D4 GEP arm's shape
#   IRStore(ssa(ak), ssa(fk), 64)                      ; the ares/beaw arm's shape
#
# PROVENANCE. Designed as a CORE 3+1 (docs/design/p06b/proposal_A.md and
# proposal_B.md, two blind proposers, converged mechanism). Ground truth for
# every claim below was measured on the module the converter actually walks
# (`_code_llvm_by_sig(...; optimize=false, dump_module=true)` followed by the
# `["sroa","mem2reg"]` prepend `_module_has_sret` triggers at entry.jl:104-108),
# never off a raw `code_llvm` dump: post-pass, `_growend!` has EXACTLY ONE live
# aggregate store (proposal_A F1 / proposal_B C1 — SROA eliminates the sret
# staging alloca and its 8-byte memcpy, and the `%oob*` siblings are in
# Bennett-utzc-pruned dead blocks). NO live ArrayType aggregate store exists, so
# this arm is StructType-only.
#
# ============================================================================
# WHY THE DECOMPOSITION IS EXACT, DETERMINISTIC AND REVERSIBLE (klgz discipline)
# ============================================================================
#
# THE REPRESENTATION. Under `ptr_cells` a pointer is one Int64 **VM cell value**
# (ADR 0018 §A) handed out by BennettVM's deterministic, injective bump
# allocator (see the Bennett-jbko block above for the full statement). Write
# `φ : native address ↦ VM cell value` for that injective map and
# `κ(p, off) = φ(p) + off÷8` for the cell the model assigns to byte offset `off`
# from `p` under the word-granular stamp.
#
# THE THEOREM. For an unpacked StructType `S` with fields at byte offsets
# `o₀…o_{N-1}`, LLVM DEFINES `store S %agg, ptr %p` to be the field-wise
# sequence `store Tₖ (extractvalue %agg, k), (getelementptr S, ptr %p, 0, k)`
# for every k, plus an UNSPECIFIED write to the padding bytes. This arm emits
# exactly that sequence, so the decomposition is exact ON THE FIELDS by LLVM's
# own semantics. Three conditions make it exact IN THE CELL MODEL as well:
#
#  1. EVERY FIELD OWNS EXACTLY ONE CELL. (P3) requires `oₖ == 8k` AND
#     `field_width(k) == 64` for every k, so the fields TILE `[0, 8N)` with no
#     gaps, no overlap and NO PADDING AT ALL. Distinct fields therefore occupy
#     distinct cells and the N writes cannot alias. This is why a sub-cell field
#     (`{i64,i8}`, `{i32,i32}`) is refused rather than admitted with a narrow
#     `IRStore` width: BennettVM's `MemoryStore` writes a WHOLE cell, so a
#     sub-cell field would need a read-modify-write of the surrounding cell,
#     which the cell model does not express — and the "padding is unobservable"
#     escape hatch is an argument about what no OTHER access may name, which
#     (P5) can only check inside this function.
#
#  2. THE CELLS AGREE WITH EVERY OTHER WAY THE OBJECT IS ADDRESSED. The only
#     other admitted addressing of a struct-typed object is the BVM ADR 0020 D4
#     two-index struct GEP, which emits `IRPtrOffset(base,
#     LLVMOffsetOfElement(S,k), ew)`. This arm calls the SAME
#     `LLVM.offsetof` (never IR-text parsing, never `index * width` — Rule 5 /
#     the dv1z-7wsz discipline) and stamps the SAME `ew`, so cell agreement is a
#     SYNTACTIC IDENTITY with the D4 arm, not a claim about two code paths.
#     MEASURED on the corpus: the store target `%1` has exactly four uses — the
#     dropped `julia.write_barrier`, the aggregate store itself, and TWO
#     word-granular `getelementptr {ptr,ptr}, ptr %1, i32 0, i32 {0,1}` in
#     `%L84`. The cells this arm writes are provably the cells the existing GEP
#     arm reads. (P5) turns that measurement into an enforced predicate, and
#     (P1) removes the ONE type where D4 deliberately uses a DIFFERENT (byte)
#     granularity.
#
#  3. DETERMINISM. Nothing in the decomposition introduces a value the model did
#     not already have: the field values are `extractvalue` slot copies of an
#     `insertvalue`-built family ((P6)), the addresses are constant offsets from
#     a certified cell pointer ((P4)), and the widths come from the datalayout.
#     For a fixed program and fixed inputs every cell written is a pure function
#     of the execution trajectory, exactly as before. p06b ADDS ZERO EXPRESSIVE
#     POWER over the field-wise spelling the extractor already admits — it only
#     lets that spelling be written as one LLVM instruction.
#
# REVERSIBILITY is inherited, not argued specially: `IRExtractValue` → a
# non-destructive slot-copy `Define`, `IRPtrOffset` → `Define(dest, base, :add,
# off÷ew_bytes)`, `IRStore` → the L2/L3-logged `MemoryStore`. N independent
# single-cell writes reverse as the reverse-ordered composition of N invertible
# cell writes. BennettVM src changes: ZERO (E2E-proved by both proposers and by
# `../BennettVM.jl/test/test_p06b_aggregate_store_vm.jl`).
#
# STORE ORDER IS IMMATERIAL. Every field value is read from the SSA aggregate
# (registers), never from memory, so even the self-referential case (the target
# pointer also appearing as a field value) cannot let the writes observe each
# other. Ascending field order is chosen for determinism and diff-readability.
#
# RESIDUAL RISKS — the COMPLETE list. Every entry is a limitation this arm does
# NOT close; nothing below is a guarantee. (Hostile review found TWO defects
# that were exactly guarantees asserted in prose with no predicate behind them,
# so this list is the contract: if it is not enforced by a named predicate
# above, it is stated here as a hole.)
#
#   * **Bennett-khb2 — `:load` targets have NO CAPACITY PROOF, and this is the
#     REAL CORPUS SHAPE.** (P4c) certifies capacity for `:alloca` and `:call`
#     only. MEASURED 2026-08-06 on `_growend!`: the target
#     `%1 = load ptr, ptr %0` carries NO extent metadata of any kind, its
#     pointer operand is a GEP off a `dereferenceable(0)` ARGUMENT, and no
#     allocation root for the object exists in this function (the adequate
#     `gc_alloc_obj(…, 24, …)` is in the CALLER). Enforcement was intended to
#     fall to BennettVM's out-of-reservation check (`bennettvm-pdqx`), but that
#     check — measured — rejects only accesses landing outside ALL live
#     reservations and does NOT reject a store clobbering an ADJACENT live
#     allocation, which is what every witness actually does. Closing this needs
#     pointer provenance. Pinned as a KNOWN-ADMITTED witness in
#     `test_p06b_aggregate_store.jl` (`p06b_khb2_loadclobber`).
#   * **(P5)'s alias closure is same-slot re-loads only.** `_p06b_alias_group`
#     links pointer-result `load`s whose pointer operands share a CANONICAL slot
#     key (root ref + total constant byte offset). It does NOT link: two loads
#     of DIFFERENT slots that happen to hold the same pointer; a pointer
#     round-tripped through memory via an intervening store; a runtime-indexed
#     GEP (the key walk stops at the first non-constant index, by design). A
#     byte-granular use reached only through one of those paths is invisible to
#     (P5).
#   * bennettvm-jb6w — the two-granularity hazard is PRE-EXISTING and shared
#     verbatim with the D4 GEP arm. (P5) refuses any target this function can
#     SEE addressed at two granularities, but a CALLEE that receives the cell
#     and byte-addresses it is out of model; the closed-world check is the guard
#     there, not this arm.
#   * Bennett-uiqq — the alloca arm UNDER-RESERVES for `alloca [K x iM], i32 N`
#     (it reserves K cells and discards N). Not fixed here (it would change
#     gate-off behaviour); `_p06b_alloca_cells` refuses `N != 1` rather than
#     trust it.
#   * Bennett-6bu3 does not check field ADDRSPACE — a `{ptr addrspace(10), ptr}`
#     field is stamped 64. Inherited, not created here.
#   * an `alloca` with an UNMODELLED allocated type silently registers a name
#     while emitting nothing (see `_alloca_reservation`). (P4) refuses to
#     build on it; fixing the silent skip itself is a separate bead.
#   * `julia.gc_alloc_obj` targets WERE refused here; **Bennett-bvmd (xkl wall 8)
#     ADMITTED them**, at the byte granularity BennettVM actually reserves
#     (`_alloc_cells(::IntrinsicGCAlloc) = _byte_cells(nb)`). The emission stamps
#     `elem_width = 8` (`_root_scale`), (P4c) compares capacity in BYTE cells,
#     and (P5) inverts its accept/reject sets for that tier. Crucially the D4
#     two-index struct-GEP arm was re-stamped in the SAME change — a (P4b)-only
#     widening would merely have flipped the defect from "store word, read byte"
#     to "store byte, read word". The 416r.13 interaction (P1) is waiting on
#     turned out NOT to live here at all: the singleton headers are GLOBALS with
#     no allocation root, so the byte stamp for them still comes from the TYPE
#     predicate, which `_cell_elem_width_struct_gep` keeps as the fallback arm
#     of a UNION rather than replacing.
# ============================================================================

# (P4) Is `v` a pointer SSA value that `ptr_cells` has CERTIFIED as a real,
# MATERIALISED VM cell address? Deliberately a POSITIVE WHITELIST of the three
# producer shapes proven to leave a cell in `locals` — NOT an "is a pointer"
# test, and emphatically NOT `haskey(names, v.ref)`: `module_walk.jl`'s naming
# pass registers EVERY instruction whether or not the converter emits an
# `IRInst` for it, so registration proves nothing about materialisation.
#
#   :load   — a pointer-result `load` whose OWN pointer operand is a registered
#             SSA name lowers to `IRLoad(dest, …, 64)` (ADR 0020 D3). The
#             operand condition mirrors that arm EXACTLY and is load-bearing:
#             a `load ptr, ptr @"jl_global#N"` (bennettvm-416r.13 singleton)
#             emits NOTHING and ALIASES the dest name to the global instead, and
#             a load off an unregistered pointer is silently skipped.
#   :call   — an ALLOCATOR call returning a fresh arena cell. Restricted to a
#             NAME whitelist (`_M4_C_ALLOCATOR_NAMES` only; `julia.gc_alloc_obj`
#             is REFUSED as byte-granular — see the :448 reject and the
#             RESIDUAL RISKS list) because "call returning a pointer" is NOT
#             sufficient: the
#             `julia.gc_*` benign-prefix drop (the `benign_prefixes` tuple at
#             ~:4243, applied at ~:4282) returns `nothing` for e.g.
#             `julia.gc_loaded` while its dest name stays registered.
#             CAPACITY comes from `_p06b_call_bytes` (P4c).
#   :alloca — an alloca for which `_alloca_reservation` (the SHARED helper the
#             alloca arm itself uses) returns a reservation, with a CERTIFIED
#             word-granular capacity (P4c). `alloca { ptr, ptr }` (the natural
#             LLVM target for an aggregate store!) is NOT in that set — it is
#             the silent-skip hole.
#
# DELIBERATELY EXCLUDED, each with a reason rather than an omission:
#   * `phi ptr` / `select ptr` — Bennett-cc0 M2b stamps them with the WIDTH-0
#     SENTINEL and records their routing in `ptr_provenance` at LOWERING time
#     rather than as a value. Offsetting off one addresses a cell that was never
#     materialised: a SILENT miscompile, not a loud one. Same hazard class as
#     jbko's ptrtoint whitelist, same answer.
#   * `getelementptr` — a GEP target means the aggregate is NESTED inside a
#     larger object, and then (P5)'s use scan over the GEP RESULT says nothing
#     about how the PARENT object is addressed. Deferred rather than assumed.
#   * a pointer `Argument` — a Julia NTuple-by-ref parameter (`dereferenceable(N)
#     > 0`) is modelled as a FLAT WIRE ARRAY, not a cell, and the sret parameter
#     is claimed by the dv1z pre-walk. Both make "argument" two models under one
#     predicate; deferred.
#   * a global / ConstantExpr / alias — never a registered SSA name, so it is
#     already the pre-existing Bennett-lgzx / U114 reject (reused verbatim).
#
# Widening any of these is a one-line change PLUS a fixture. Depth-0 by design —
# no chain walk, no recursion. Returns `:load`, `:call`, `:alloca`, or `:none`.
# The constant value of `v`, or -1 if it is not a compile-time constant.
_p06b_const(v)::Int = v isa LLVM.ConstantInt ? Int(_const_int_as_int(v)) : -1

# (P4c) CAPACITY — hostile-review defect D1, a SILENT MISCOMPILE.
#
# The kind whitelist above certifies that the producer WOULD emit an `IRAlloca`
# / bump the arena. It says NOTHING about HOW MANY cells were reserved. Executed
# witness (review scratchpad `e2e2.jl` / `e2e3.jl`, 2026-08-06): an
# `alloca i64` (ONE cell) or a `malloc(8)` (ONE cell) receiving a decomposed
# TWO-field aggregate store overwrote the NEXT allocation's cell on both tiers —
# EXPECTED 999, ACTUAL 42, with NO error raised. The original arm's message
# asserted a reservation guarantee that no predicate checked; this function is
# that predicate.
#
# Returns the statically CERTIFIED capacity in 64-bit cells, or -1 for
# "statically unknown" (see the `:load` disclosure in the arm).
function _p06b_alloca_cells(v, names::Dict{_LLVMRef, Symbol}, ptr_cells::Bool)::Int
    r = _alloca_reservation(v, names, ptr_cells)
    r === nothing && return -1
    ew, nop = r
    # `[K x i8]` reserves K BYTE cells, not word cells — the decomposition's
    # cell arithmetic does not apply, so only a 64-bit element width counts.
    ew == 64 || return 0
    # N1: for an ArrayType allocated type the arm DISCARDS the count operand
    # (Bennett-uiqq). Refuse anything but an explicit count of 1 rather than
    # certify a reservation the arm does not make.
    et = LLVM.LLVMType(LLVM.API.LLVMGetAllocatedType(v.ref))
    if et isa LLVM.ArrayType
        ops = LLVM.operands(v)
        cnt = isempty(ops) ? 1 : _p06b_const(ops[1])
        cnt == 1 || return 0
    end
    # A RUNTIME count is not a static capacity proof.
    return nop isa ConstOperand ? nop.value : 0
end

# The byte size an allocator call reserves, or -1 if not a compile-time
# constant. Operand positions are the callee's own ABI (the callee itself is the
# LAST operand, per this file's convention).
function _p06b_call_bytes(v)::Int
    cn = _heap_callee_name(v)
    ops = LLVM.operands(v)
    n = length(ops)
    if cn == "malloc"
        return n >= 2 ? _p06b_const(ops[1]) : -1               # malloc(size)
    elseif cn == "calloc"
        if n >= 3
            a = _p06b_const(ops[1]); b = _p06b_const(ops[2])
            return (a < 0 || b < 0) ? -1 : a * b               # calloc(n, size)
        end
        return -1
    elseif cn == "realloc"
        return n >= 3 ? _p06b_const(ops[2]) : -1               # realloc(p, size)
    end
    return -1
end

# Returns `(kind, cells)`. `cells >= 0` is a CERTIFIED capacity in 64-bit cells;
# `cells == -1` means statically unknown (only ever returned for `:load`, whose
# extent is not knowable at the store site — see the arm's disclosure).
# COUPLING — SECOND CONSUMER (Bennett-57hd / ADR 0017 §4b), clause (iv).
# `_57hd_canon` forwards a load to an aggregate store's field ONLY when the
# store's target root certifies here. Without that gate the walk could "prove" a
# copy step through a store the extraction never materialises as cells — §4a
# clause (i)'s own disclosure ("does not provide sentinel-freedom for
# load-sourced values") is that hole one hop up. Pinned by gate (N) of
# `test_57hd_value_identity.jl`.
function _p06b_cell_ptr_target_kind(v, names::Dict{_LLVMRef, Symbol},
                                    ptr_cells::Bool,
                                    suppressed::Set{_LLVMRef})
    v.ref == C_NULL && return (:none, 0)
    ty = LLVM.value_type(v)
    ty isa LLVM.PointerType || return (:none, 0)
    LLVM.addrspace(ty) == 0 || return (:none, 0)  # addrspace-0 only (cf. 7wsz)
    v isa LLVM.Instruction || return (:none, 0)
    # (P4b') D1b — CONSULT WHAT THE WALK ACTUALLY EMITTED, not what the arm
    # would do in isolation. `module_walk.jl`'s emission loop `continue`s past
    # every ref in `sret_writes.suppressed` / `.call_return_suppressed` /
    # `consumed_sret.suppressed`, so a target rooted at a SUPPRESSED box alloca
    # certifies under the type rules while NO `IRAlloca` is ever emitted for it.
    v.ref in suppressed && return (:none, 0)
    opc = LLVM.opcode(v)
    if opc == LLVM.API.LLVMLoad
        lops = LLVM.operands(v)
        length(lops) >= 1 || return (:none, 0)
        return haskey(names, lops[1].ref) ? (:load, -1) : (:none, 0)
    elseif opc == LLVM.API.LLVMCall
        cn = _heap_callee_name(v)
        # Bennett-bvmd (xkl wall 8): `julia.gc_alloc_obj` is ADMITTED, at the
        # BYTE granularity BennettVM actually reserves for it
        # (`_alloc_cells(::IntrinsicGCAlloc) = _byte_cells(nbytes)`,
        # intrinsics.jl:256-257). The capacity is returned in the TARGET'S OWN
        # cells — byte cells here, word cells for `malloc` — and (P4c) converts
        # the requirement into the same unit via the store's own stamp. A
        # non-constant `nbytes` certifies 0, exactly as `malloc` does.
        if cn == "julia.gc_alloc_obj"
            cops = LLVM.operands(v)
            nb = length(cops) >= 3 ? _p06b_const(cops[2]) : -1
            return (:gcalloc, nb < 0 ? 0 : nb)
        end
        cn in _M4_C_ALLOCATOR_NAMES || return (:none, 0)
        b = _p06b_call_bytes(v)
        return (:call, b < 0 ? 0 : b ÷ 8)   # a non-constant size certifies 0
    elseif opc == LLVM.API.LLVMAlloca
        _alloca_reservation(v, names, ptr_cells) === nothing && return (:none, 0)
        c = _p06b_alloca_cells(v, names, ptr_cells)
        return (:alloca, c < 0 ? 0 : c)     # a runtime count certifies 0
    end
    return (:none, 0)
end

# Human-readable description of a REJECTED aggregate-store target, for the (P4)
# fail-loud. Says WHY, not just WHAT.
function _p06b_target_kind_name(v, suppressed::Set{_LLVMRef}=Set{_LLVMRef}())::String
    v.ref == C_NULL && return "a null value ref"
    v.ref in suppressed &&
        return "a value the module walk SUPPRESSED (an sret / consumed-sret " *
               "box alloca or its producing call — `module_walk.jl`'s emission " *
               "loop `continue`s past it), so NO IRInst is emitted for it at " *
               "all and nothing ever reserved the cells this store would write"
    ty = LLVM.value_type(v)
    ty isa LLVM.PointerType ||
        return "a non-pointer value of type $(string(ty))"
    LLVM.addrspace(ty) == 0 ||
        return "a pointer in addrspace $(LLVM.addrspace(ty)), not the flat " *
               "addrspace 0 arena"
    LLVM.API.LLVMIsAArgument(v.ref) != C_NULL &&
        return "a pointer function ARGUMENT (a `dereferenceable(N)` parameter " *
               "is modelled as a flat wire array, not a cell, and the sret " *
               "parameter is claimed by the dv1z pre-walk — deferred)"
    v isa LLVM.Instruction ||
        return "a non-instruction value (global / alias / ConstantExpr)"
    opc = LLVM.opcode(v)
    if opc == LLVM.API.LLVMAlloca
        et = LLVM.LLVMType(LLVM.API.LLVMGetAllocatedType(v.ref))
        return "an `alloca $(string(et))`, whose allocated type the alloca arm " *
               "SILENTLY SKIPS — it emits NO IRAlloca, so nothing ever " *
               "reserved the cells this store would write"
    elseif opc == LLVM.API.LLVMLoad
        return "a `load` whose own pointer operand is not a registered SSA " *
               "name (an aliased singleton-data global load emits no IRLoad)"
    elseif opc == LLVM.API.LLVMCall
        # Bennett-bvmd RETIRED the `julia.gc_alloc_obj` paragraph that used to
        # live here. That tier is now ADMITTED at BYTE granularity (see
        # `_p06b_cell_ptr_target_kind`), so `_p06b_cell_ptr_target_kind` never
        # returns `:none` for it and this function is never reached with one. A
        # gc_alloc target with a NON-CONSTANT `nbytes` certifies capacity 0 and
        # is refused by (P4c)'s capacity message instead — which is accurate
        # about the reason, where a "byte-granular, refused" paragraph would
        # not be. (The retired text also pinned `bennettvm-9n3y`, a DANGLING ID
        # in both trackers; the live filings are `Bennett-zdd6` for the
        # literal-`{i64,ptr}` mis-stamp discriminator and `bennettvm-rxgy` for
        # byte-exact memmove.)
        cn_r = _heap_callee_name(v)
        return "a `call` to '$(cn_r)', which is not a recognised cell allocator"
    elseif opc == LLVM.API.LLVMPHI || opc == LLVM.API.LLVMSelect
        return "a `$(_llvm_opcode_name(opc))` pointer, which carries the " *
               "Bennett-cc0 M2b WIDTH-0 SENTINEL — its routing is recorded in " *
               "`ptr_provenance` at lowering time, so no cell was ever " *
               "materialised to offset from"
    end
    return "a `$(_llvm_opcode_name(opc))`"
end

# (P5) CELL-GRANULARITY AGREEMENT over the target's OTHER address-forming uses.
#
# MEASURED HAZARD (proposal_B §2.2 P5): BennettVM recovers the cell index from
# an `IRPtrOffset` as `offset_bytes ÷ (elem_width ÷ 8)`. A single-index
# `getelementptr i8, ptr %obj, i32 8` therefore lands on cell 8, while a
# two-index `getelementptr {ptr,ptr}, ptr %obj, i32 0, i32 1` on the SAME object
# lands on cell 1 — TWO CELLS FOR ONE BYTE OFFSET. That split is live today in
# the push! ROOT (`%"new::Array"` is both byte-addressed at 8/16 and
# struct-addressed at fields 0/1). Reading through one of two disagreeing maps
# is bennettvm-jb6w; WRITING a whole aggregate through one of them is worse, so
# this arm refuses rather than picks a winner. Measured cost of refusing: ZERO
# frontier progress (the root's own next wall is the Bennett-37mt/8bys memcpy,
# two instructions later).
#
# EVERY `getelementptr` use of the target must be either
#   * a two-index struct GEP whose GEPSourceElementType IS the stored struct
#     type, with the leading constant-0 base step (word granularity, our
#     granularity), or
#   * a single-index GEP at the CONSTANT index 0 (byte offset 0 maps to cell 0
#     under every stamp, so it cannot disagree).
# Non-GEP uses (the store itself, `load`, `julia.write_barrier`, passing the
# cell to a call) are cell-OPAQUE and accepted; the closed-world check, not this
# arm, is the guard on what a callee does with a cell it receives.
#
# Returns `nothing` when every use agrees, else a SHORT STRING naming the
# offending use (so the fail-loud says which one).
# D3 — the alias group of the target. The scan below must be OBJECT-scoped, not
# SSA-scoped: `%slot = load ptr, ptr %root` and a later `%slot2 = load ptr, ptr
# %root` name the SAME object under two SSA names, and a scan over `%slot`
# alone never sees `%slot2`'s byte GEP. That is not a synthetic worry — it is
# the canonical Julia GC RELOAD-AFTER-SAFEPOINT shape, so it is live corpus
# territory (hostile-review defect D3, repro `probe1_realias` / `probe25`).
#
# The group is `pv` plus, when `pv` is a `load`, every other `load` in the same
# function whose POINTER OPERAND is the same SSA ref. That is the closure this
# arm can prove; see the arm's disclosure for what it does NOT close.
# N2 (hostile review round 2) — the alias key must be CANONICAL, not syntactic.
# Keying the group on the load's pointer-operand SSA *ref* meant two IDENTICAL
# `getelementptr i8, ptr %slot, i64 0` instructions produced two different keys
# and defeated the scan entirely — and `optimize=false` (which this extractor
# mandates, Rule 5) emits redundant GEPs routinely. Executed witness
# `scratchpad/hostile2.ll h14_redundant_gep`: ADMITTED, VM returned 0 where
# LLVM says 42.
#
# `_p06b_slot_key` folds a chain of ALL-CONSTANT-index GEPs into
# `(root_ref, total_byte_offset)`, so every syntactic spelling of the same
# address collapses to one key. A non-constant index stops the walk (that GEP
# result becomes its own root) — sound, because two runtime-indexed addresses
# cannot be proven equal here. Depth-bounded like the other walkers in this file.
#
# COUPLING — SECOND CONSUMER (Bennett-57hd / ADR 0017 §4b). `_57hd_canon` uses
# this key as its notion of "the same slot" for BOTH its store-forward and its
# same-slot-reload rules, and `_57hd_write_footprint` uses it to name the
# `(root, lo, hi)` a store or a mem intrinsic writes. The variable-index
# stop-the-walk rule is LOAD-BEARING there too, in the same direction: two
# runtime-indexed addresses get DIFFERENT roots, are therefore never provably
# disjoint, and clobber. Any change here lands in `test_p06b_aggregate_store.jl`
# AND in `test_57hd_value_identity.jl` gates (B)/(C)/(N).
function _p06b_slot_key(v::LLVM.Value, depth::Int=0)::Tuple{_LLVMRef,Int}
    depth > 8 && return (v.ref, 0)
    (v isa LLVM.Instruction && LLVM.opcode(v) == LLVM.API.LLVMGetElementPtr) ||
        return (v.ref, 0)
    ops = LLVM.operands(v)
    length(ops) >= 2 || return (v.ref, 0)
    sty = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(v.ref))
    off = 0
    if length(ops) == 2
        ops[2] isa LLVM.ConstantInt || return (v.ref, 0)
        stride = if sty isa LLVM.IntegerType
            max(Int(LLVM.width(sty)) ÷ 8, 1)
        else
            dl = LLVM.datalayout(LLVM.parent(LLVM.parent(LLVM.parent(v))))
            Int(LLVM.storage_size(dl, sty))
        end
        off = Int(_const_int_as_int(ops[2])) * stride
    elseif length(ops) == 3 && sty isa LLVM.StructType
        (ops[2] isa LLVM.ConstantInt && _const_int_as_int(ops[2]) == 0) ||
            return (v.ref, 0)
        ops[3] isa LLVM.ConstantInt || return (v.ref, 0)
        dl = LLVM.datalayout(LLVM.parent(LLVM.parent(LLVM.parent(v))))
        off = Int(LLVM.offsetof(dl, sty, _const_int_as_int(ops[3])))
    else
        return (v.ref, 0)
    end
    rroot, roff = _p06b_slot_key(ops[1], depth + 1)
    return (rroot, roff + off)
end

# D3 — the alias group of the target. The scan below must be OBJECT-scoped, not
# SSA-scoped: `%slot = load ptr, ptr %root` and a later `%slot2 = load ptr, ptr
# %root` name the SAME object under two SSA names, and a scan over `%slot`
# alone never sees `%slot2`'s byte GEP. That is not a synthetic worry — it is
# the canonical Julia GC RELOAD-AFTER-SAFEPOINT shape, so it is live corpus
# territory (hostile-review defect D3, repro `probe1_realias` / `probe25`).
#
# The group is `pv` plus, when `pv` is a `load`, every other pointer-result
# `load` in the same function whose pointer operand has the SAME CANONICAL SLOT
# KEY (N2). That is the closure this arm can prove; the arm's RESIDUAL RISKS
# list states what it does NOT close.
function _p06b_alias_group(pv::LLVM.Value)::Vector{LLVM.Value}
    grp = LLVM.Value[pv]
    (pv isa LLVM.Instruction && LLVM.opcode(pv) == LLVM.API.LLVMLoad) || return grp
    pops = LLVM.operands(pv)
    isempty(pops) && return grp
    key = _p06b_slot_key(pops[1])
    func = LLVM.parent(LLVM.parent(pv))
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref == pv.ref && continue
        LLVM.opcode(inst) == LLVM.API.LLVMLoad || continue
        LLVM.value_type(inst) isa LLVM.PointerType || continue
        iops = LLVM.operands(inst)
        (!isempty(iops) && _p06b_slot_key(iops[1]) == key) || continue
        push!(grp, inst)
    end
    return grp
end

#
# Bennett-bvmd — TIER PARAMETRISATION. `ew_store` is the stamp the decomposition
# will actually emit (`8 · scale(root)`, or 64 when the root's scale is
# unprovable). The two regimes are BOTH live in the corpus and neither may be
# dropped:
#
#   * ew_store == 64 (WORD tier — every target admitted before bvmd, plus every
#     scale-unknown `:load` target, which is `_growend!`'s own shape): the rule
#     below is TODAY'S RULE VERBATIM. A single-index GEP is refused by
#     construction, the two-index arm must carry the stored struct type and the
#     leading constant 0. Byte-identical — the C tier and the whole
#     (D2)/(D7)/(N2)/(D3) surface do not move.
#   * ew_store == 8 (BYTE tier — the newly admitted `julia.gc_alloc_obj`
#     targets): the accept/reject sets INVERT, because the arm's own emission is
#     byte-granular. The predicate becomes a STAMP COMPARISON against
#     `_cell_elem_width_struct_gep` / `_const_gep_stamp` — the emitter's own
#     functions — so agreement is a syntactic identity, not a claim about two
#     code paths.
#
# NOTE on what (P5) is NOT asked to carry any more. For a SCALE-KNOWN root the
# stream check `_check_scale_coherence!` covers a strict SUPERSET of this scan
# (every emitted node derived from the root, at any GEP depth, including nodes
# from construction sites this file does not own). (P5) is retained regardless,
# because for a SCALE-UNKNOWN root — `_growend!`'s `%1 = load ptr, ptr %0` off a
# `dereferenceable(0)` argument — the stream check is silent and (P5) is the
# ONLY guard.
function _p06b_scan_uses(pv::LLVM.Value, st::LLVM.StructType, sib::Bool,
                         ew_store::Int, names::Dict{_LLVMRef, Symbol},
                         ptr_cells::Bool)::Union{Nothing,String}
    where_ = sib ? "a SIBLING re-load of the same slot (`$(string(pv))`), via " : ""
    for u in LLVM.uses(pv)
        usr = LLVM.user(u)
        usr isa LLVM.Instruction || return "$(where_)a non-instruction user"
        LLVM.opcode(usr) == LLVM.API.LLVMGetElementPtr || continue
        ops = LLVM.operands(usr)
        (length(ops) >= 1 && ops[1].ref == pv.ref) ||
            return "$(where_)a getelementptr that consumes the pointer as an " *
                   "INDEX operand, not as the base"
        if ew_store != 64
            # BYTE tier — compare the stamp this use will actually be emitted
            # with against the stamp the decomposition will emit.
            sty_b = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(usr.ref))
            ew_use = if length(ops) == 3 && sty_b isa LLVM.StructType
                _cell_elem_width_struct_gep(pv, sty_b, names, ptr_cells)
            elseif length(ops) == 2
                _const_gep_stamp(usr)
            else
                nothing
            end
            ew_use === nothing && return "$(where_)the " *
                "$(length(ops) - 1)-index getelementptr `$(string(usr))`, " *
                "whose emitted cell stamp this arm cannot determine"
            ew_use == ew_store && continue
            return "$(where_)the getelementptr `$(string(usr))`, which is " *
                   "emitted at elem_width $(ew_use) (cell stride " *
                   "$(ew_use ÷ 8) byte(s)) while this store's target is " *
                   "addressed at elem_width $(ew_store) (cell stride " *
                   "$(ew_store ÷ 8) byte(s))"
        end
        if length(ops) == 3
            sty = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(usr.ref))
            sty.ref == st.ref || return "$(where_)the two-index getelementptr " *
                "`$(string(usr))`, whose source element type $(string(sty)) is " *
                "NOT the stored struct type $(string(st))"
            (ops[2] isa LLVM.ConstantInt && _const_int_as_int(ops[2]) == 0) ||
                return "$(where_)the two-index getelementptr `$(string(usr))`, " *
                       "whose first index is not the constant 0"
        elseif length(ops) == 2
            # D2 — the index-0 CARVE-OUT IS DROPPED. It used to admit
            # `gep i8, ptr %p, 0` on the reasoning that byte offset 0 maps to
            # cell 0 under every stamp. True of the GEP itself — but it emits
            # `IRPtrOffset(_, _, 0, 8)`, a FRESH BYTE-GRANULAR BASE, and the
            # scan is one level deep, so a `gep i8, ptr %g0, 8` off it
            # re-derived byte-cell 8 while the store wrote cell 1: exactly the
            # CW-D4 / 9n3y split this predicate exists to refuse (repro
            # `probe2_gep_of_gep`). Refusing costs zero frontier progress
            # (measured), so there is no reason to keep the hole.
            #
            # D7 — name the granularity ACCURATELY. A 2-op GEP strides by its
            # SOURCE ELEMENT TYPE, which is only "byte" when that type is i8.
            sty2 = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(usr.ref))
            kind = if sty2 isa LLVM.StructType
                "struct-strided"
            elseif sty2 isa LLVM.IntegerType && LLVM.width(sty2) == 8
                "BYTE-granular"
            else
                "$(string(sty2))-strided"
            end
            return "$(where_)the single-index $(kind) getelementptr " *
                   "`$(string(usr))` (source element type $(string(sty2)))"
        else
            return "$(where_)the $(length(ops) - 1)-index getelementptr " *
                   "`$(string(usr))`"
        end
    end
    return nothing
end

function _p06b_granularity_violation(pv::LLVM.Value, st::LLVM.StructType,
                                     ew_store::Int,
                                     names::Dict{_LLVMRef, Symbol},
                                     ptr_cells::Bool)::Union{Nothing,String}
    grp = _p06b_alias_group(pv)
    for (i, q) in enumerate(grp)
        v = _p06b_scan_uses(q, st, i > 1, ew_store, names, ptr_cells)
        v === nothing || return v
    end
    return nothing
end

# (P6') D4 — CHAIN ROOT certification. (P6) checked only the OUTERMOST
# `insertvalue`; the chain it heads may be rooted in a value BennettVM's
# `agg_dests` never registers (repro `probe14_loadbase_iv`:
# `insertvalue (load {ptr,ptr}), …`). Because `IRInsertValue` has NO
# membership guard of its own on `ingest`'s side — only `IRExtractValue` does —
# such a chain died as a CONTEXTLESS KeyError in the WRONG repo.
#
# A chain is certified iff every link is an `insertvalue` and the root is
# `zeroinitializer` / `undef` / `poison` — i.e. a constant aggregate that
# contributes no cell value and that the 6bu3 arm already lowers to the
# `ZeroAggSentinel` / a fresh slot family. Depth-bounded like the other
# provenance walkers in this file. Returns `nothing` if certified, else a short
# description of the offending root.
function _p06b_agg_chain_root_violation(v, depth::Int=0)::Union{Nothing,String}
    depth > 8 && return "an `insertvalue` chain deeper than 8 links"
    if v isa LLVM.ConstantAggregateZero || v isa LLVM.UndefValue ||
       v isa LLVM.PoisonValue
        return nothing                       # certified root
    end
    (v isa LLVM.Instruction && LLVM.opcode(v) == LLVM.API.LLVMInsertValue) ||
        return "a `$(v isa LLVM.Instruction ? _llvm_opcode_name(LLVM.opcode(v)) :
                     "non-instruction")` value (`$(string(v))`)"
    ops = LLVM.operands(v)
    isempty(ops) && return "a malformed `insertvalue` with no operands"
    return _p06b_agg_chain_root_violation(ops[1], depth + 1)
end

"""
    _gc_alloc_root_ref(val, depth=0) -> Union{Nothing, _LLVMRef}

Bennett-vbv9 (2026-06): the ARENA analogue of `_alloca_root_ref`. Walk the
producer chain from a pointer SSA value back to its underlying
`julia.gc_alloc_obj` CALL — the closed-world arena allocation (Bennett-r92o /
CW-D3 Lever 2; BennettVM ADR 0021 D3 bump floor). Returns the call's LLVM ref,
or `nothing` if the chain doesn't bottom out in a `julia.gc_alloc_obj` call
(e.g. function parameter, global, ptr-phi, ptr-select, alloca).

Mirrors `_alloca_root_ref`'s const-GEP recursion EXACTLY (same depth-8 bound,
same `LLVMGetElementPtr` opcode walk, same `gep_ops[1]` base step), differing
only in the bottom-out predicate: a Call instruction whose LAST operand (the
callee, per the `cname = LLVM.name(ops[n_ops])` convention used throughout this
file) is named `julia.gc_alloc_obj`.

The real fdict field-init dst-GEP is `getelementptr inbounds i8, ptr %obj,
i32 OFF` (a single-index i8 GEP off the gc_alloc result — empirically verified
Bennett-vbv9 STEP 0c), so the recursion is a single GEP hop to the call.

Used by `_handle_memcpy_global_src` (G3) ONLY under `ptr_cells=true` — an
arena dst makes no sense on the circuit path, which has no gc_alloc cell model.
"""
function _gc_alloc_root_ref(val::LLVM.Value, depth::Int=0)::Union{Nothing, _LLVMRef}
    depth > 8 && return nothing
    val.ref == C_NULL && return nothing
    if val isa LLVM.Instruction && LLVM.opcode(val) == LLVM.API.LLVMCall
        call_ops = LLVM.operands(val)
        n = length(call_ops)
        n >= 1 || return nothing
        # Callee is the LAST operand (file-wide convention). Read its name; a
        # missing/exotic callee name simply means "not our gc_alloc_obj".
        callee_name = try
            LLVM.name(call_ops[n])
        catch e
            e isa InterruptException && rethrow()
            return nothing
        end
        return callee_name == "julia.gc_alloc_obj" ? val.ref : nothing
    end
    if val isa LLVM.Instruction && LLVM.opcode(val) == LLVM.API.LLVMGetElementPtr
        gep_ops = LLVM.operands(val)
        length(gep_ops) >= 1 || return nothing
        return _gc_alloc_root_ref(gep_ops[1], depth + 1)
    end
    return nothing
end

"""
    _gc_alloc_root_offset(val, depth=0) -> Union{Nothing, Int}

Bennett-sy29 (2026-08, xkl wall 9): the BYTE OFFSET of `val` from the
`julia.gc_alloc_obj` ARENA root that `_gc_alloc_root_ref` finds for it, or
`nothing` when the offset is not a compile-time constant (any runtime GEP index)
or the GEP shape is one this walker does not flatten.

`_gc_alloc_root_ref` returns only the ROOT; it deliberately says nothing about
WHERE in the object the pointer lands, because vbv9's only consumer (the
global-src dst arm) needed the root alone. The arena-src/arena-dst memcpy arm
needs the offset as well, for one reason:

  **The byte tier places a 64-bit value in exactly ONE cell, at that value's
  BASE BYTE ADDRESS** (cells `+1…+7` are never named — the bennettvm-416r.13 /
  9n3y / vbv9 convention). An 8-byte chunk starting at byte 4 of the object
  therefore has no faithful single-cell gather: it straddles the named cell at
  byte 0 and the named cell at byte 8, and neither `IRLoad` can express it.

(SC) (`_check_scale_coherence!`) does NOT detect this. `gep i8 %obj, 4` off a
byte-tier root is *perfectly scale-coherent* — stamp 8, scale 1, cell +4 — so
the coherence invariant is satisfied by a pointer that nonetheless names a cell
no 64-bit value lives at. This is a genuinely NEW predicate, not a copy of
vbv9's G7 (which checks the *global's* offset, on the src side, and leaves the
arena dst's own offset unchecked — that residual corner is filed, see the arm).

(Wording note: "detect", not the obvious verb — `test_uinn_catch_narrowing.jl`
statically scans every line of `src/extract/*.jl` for the `catch` KEYWORD and
does not skip docstring bodies, so that verb in prose reads as an unguarded
`catch` site and fails the meta-test. The scanner fix is Bennett-gb39.)

Index arithmetic mirrors `_global_root_and_offset` exactly (first index strides
the GEP source element type; a non-zero first index into an `ArrayType` source
is refused; second+ indices stride the array's integer element), differing only
in walking INSTRUCTION GEPs rather than `ConstantExpr` GEPs and in bottoming out
at the `julia.gc_alloc_obj` call. Depth bound is `_gc_alloc_root_ref`'s.
"""
function _gc_alloc_root_offset(val::LLVM.Value, depth::Int=0)::Union{Nothing, Int}
    # Reuse the ROOT predicate verbatim so the two walkers cannot disagree about
    # what an arena root is, then defer the arithmetic to the SHARED walker.
    _gc_alloc_root_ref(val, depth) === nothing && return nothing
    return _root_byte_offset(val, depth)
end

"""
    _root_byte_offset(val, depth=0) -> Union{Nothing, Int}

Bennett-sy29 (hostile-review fix D2): the constant byte offset of `val` from its
ALLOCATION ROOT, whatever kind that root is — the root-kind-agnostic sibling of
`_gc_alloc_root_offset`, and the offset half of `_root_scale`'s capacity.

Recursion is `_bvmd_root_ref`'s exactly (const-GEP chain, `gops[1]` base step,
`_BVMD_ROOT_DEPTH` bound) so the offset it computes is measured from precisely
the root `_root_scale` reports a capacity for. Bottoms out at ANY non-GEP
instruction with offset 0 — the root itself. Returns `nothing` when the chain
cannot be flattened to a constant: a runtime GEP index, a struct-typed GEP
source, a non-zero first index into an `ArrayType` source, or depth overflow.

Index arithmetic mirrors `_global_root_and_offset`.
"""
function _root_byte_offset(val::LLVM.Value, depth::Int=0)::Union{Nothing, Int}
    depth > _BVMD_ROOT_DEPTH && return nothing
    val.ref == C_NULL && return nothing
    val isa LLVM.Instruction || return nothing
    LLVM.opcode(val) == LLVM.API.LLVMGetElementPtr || return 0   # the root
    gops = LLVM.operands(val)
    length(gops) >= 2 || return nothing
    srcty = try
        LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(val.ref))
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    idx_off = 0
    for i in 2:length(gops)
        iv = gops[i]
        iv isa LLVM.ConstantInt || return nothing        # runtime index
        ival = Int(LLVM.API.LLVMConstIntGetSExtValue(iv.ref))
        if i == 2
            if srcty isa LLVM.IntegerType
                idx_off += ival * div(LLVM.width(srcty), 8)
            elseif srcty isa LLVM.ArrayType
                ival == 0 || return nothing
            else
                return nothing
            end
        else
            srcty isa LLVM.ArrayType || return nothing
            inner = LLVM.eltype(srcty)
            inner isa LLVM.IntegerType || return nothing
            idx_off += ival * div(LLVM.width(inner), 8)
        end
    end
    sub = _root_byte_offset(gops[1], depth + 1)
    sub === nothing && return nothing
    return sub + idx_off
end

"""
    _param_ptr_root_ref(val, depth=0) -> Union{Nothing, _LLVMRef}

Bennett-u2kk (2026-06): the POINTER-PARAMETER analogue of `_alloca_root_ref` /
`_gc_alloc_root_ref`. Walk the producer chain from a pointer SSA value back to
its underlying function POINTER PARAMETER — the closed-world caller-supplied
cell (e.g. the `Dict` struct-by-ref param `h::Dict`; BennettVM ADR 0018 §A flat
address space). Returns the parameter's LLVM ref, or `nothing` if the chain
doesn't bottom out in a pointer-typed Argument (e.g. alloca, global, gc_alloc
call, ptr-phi, ptr-select, or an INTEGER argument — never a cell root).

Mirrors `_alloca_root_ref`'s const-GEP recursion EXACTLY (same depth-8 bound,
same `LLVMGetElementPtr` opcode walk, same `gep_ops[1]` base step), differing
only in the bottom-out predicate: an LLVM `Argument` whose `value_type` is a
`PointerType`. (The PointerType guard is deliberate — an integer-typed argument
carries a value, not a cell address, so it is never a memcpy-dst cell root.)

The real rehash! field-init dst-GEP is `getelementptr inbounds i8, ptr
%"h::Dict", i32 OFF` (a single-index i8 GEP off the Dict pointer param, after
the extractor's addrspace-demotion preprocessing folds the p11 addrspacecast),
so the recursion is a single GEP hop to the Argument. The same shape the proven
setindex! field STORES already lower off `h::Dict` (see probe_field_gep).

Used by `_handle_memcpy_global_src` (G3) ONLY under `ptr_cells=true` — a param
cell dst makes no sense on the circuit path, which has no BVM cell model nor a
history tape to reverse the destructive field overwrite (see the reversibility
note at the G4 branch below).
"""
function _param_ptr_root_ref(val::LLVM.Value, depth::Int=0)::Union{Nothing, _LLVMRef}
    depth > 8 && return nothing
    val.ref == C_NULL && return nothing
    if LLVM.API.LLVMIsAArgument(val.ref) != C_NULL &&
       LLVM.value_type(val) isa LLVM.PointerType
        return val.ref
    end
    if val isa LLVM.Instruction && LLVM.opcode(val) == LLVM.API.LLVMGetElementPtr
        gep_ops = LLVM.operands(val)
        length(gep_ops) >= 1 || return nothing
        return _param_ptr_root_ref(gep_ops[1], depth + 1)
    end
    return nothing
end

# ---- Bennett-583s / CW-D: GenericMemory `.data`-base ptrtoint provenance ----
#
# The `setindex!`/`getindex`/`rehash!` @boundscheck (under --check-bounds=yes)
# lowers to a base-cancelling difference of two `.data`-base pointers:
#
#   %g     = getelementptr {i64,ptr}, ptr %mem, i32 0, i32 1  ; field-1 = .data
#   %data  = load ptr, ptr %g
#   %elem  = getelementptr i8, ptr %data, i64 %off
#   %b     = ptrtoint ptr %data to i64
#   %e     = ptrtoint ptr %elem to i64
#   %d     = sub i64 %e, %b                                   ; == %off (base cancels)
#   %c     = icmp ult i64 %d, %len                            ; dead throw @boundscheck
#
# `_memdata_root` returns the Memory struct-base ref of a `.data`-provenanced
# pointer (its identity); `_verify_memdata_bounds_cluster` proves the ptrtoint
# result NEVER escapes the same-Memory base-cancelling `sub(ptrtoint,ptrtoint)`
# pattern. Both are the SOLE soundness boundary (see the ptrtoint arm below):
# `sub(ptrtoint(base+off), ptrtoint(base)) = off` is base-INDEPENDENT (matches
# the native oracle), but a base-DEPENDENT / escaping address would not.

# Is `st` the Julia GenericMemory HEADER struct — the LITERAL (unnamed)
# 2-element `{ i64, ptr }` (length, data-ptr)? CW-D4 (bennettvm-9n3y): this
# predicate scopes the byte-granular header-GEP stamp below. Literalness
# discriminates Julia-vs-C for ORDINARY field-access GEPs: Julia codegen emits
# the header as an anonymous literal struct type, while clang emits NAMED
# `%struct.T` types for C struct field accesses (test_haiy/test_nd45 pins).
# KNOWN RESIDUAL RISK (bennettvm-jb6w, hostile-review-confirmed on clang
# 18.1.3): clang's SysV-ABI register-coercion SPILL of a by-value
# `struct {long; void*;}` emits a LITERAL `{i64,ptr}` GEP for the spill while
# later accesses use the named type — the same field would be stamped 8 by one
# GEP and 64 by the other (different VM cells, silent). No committed fixture
# trips it; the fix (provenance-based discrimination or an ingest-time
# two-granularity loud guard) is tracked in that bead.
function _is_genericmemory_header_struct(st)::Bool
    st isa LLVM.StructType || return false
    Bool(LLVM.API.LLVMIsLiteralStruct(st)) || return false
    els = LLVM.elements(st)
    length(els) == 2 || return false
    (els[1] isa LLVM.IntegerType && LLVM.width(els[1]) == 64) || return false
    return els[2] isa LLVM.PointerType
end

# Is `gepval` a field-1 GEP of a `{i64,ptr}` GenericMemory struct (`.data`)?
function _is_memdata_field1_gep(gepval)::Bool
    gepval isa LLVM.Instruction || return false
    LLVM.opcode(gepval) == LLVM.API.LLVMGetElementPtr || return false
    ops = LLVM.operands(gepval)
    length(ops) == 3 || return false
    st = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(gepval.ref))
    _is_genericmemory_header_struct(st) || return false
    # indices [0, 1] (field-1)
    (ops[2] isa LLVM.ConstantInt && _const_int_as_int(ops[2]) == 0) || return false
    (ops[3] isa LLVM.ConstantInt && _const_int_as_int(ops[3]) == 1) || return false
    return true
end

# The Memory root ref of a memdata-provenanced pointer value, or `nothing`.
# Seed: `load ptr` of a `{i64,ptr}` field-1 GEP → the struct base ref.
# Propagate through `getelementptr i8` (the elem byte-offset GEP) and identity
# casts. Depth-bounded like `_param_ptr_root_ref` / `_alloca_root_ref`.
function _memdata_root(v, depth::Int=0)::Union{Nothing, _LLVMRef}
    depth > 8 && return nothing
    v isa LLVM.Instruction || return nothing
    opc = LLVM.opcode(v)
    if opc == LLVM.API.LLVMLoad
        LLVM.value_type(v) isa LLVM.PointerType || return nothing
        p = LLVM.operands(v)[1]
        _is_memdata_field1_gep(p) || return nothing
        return LLVM.operands(p)[1].ref                 # the {i64,ptr} struct base
    elseif opc == LLVM.API.LLVMGetElementPtr
        # propagate through the i8 byte-offset GEP only
        st = LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(v.ref))
        (st isa LLVM.IntegerType && LLVM.width(st) == 8) || return nothing
        return _memdata_root(LLVM.operands(v)[1], depth + 1)
    elseif opc in (LLVM.API.LLVMAddrSpaceCast, LLVM.API.LLVMBitCast)
        return _memdata_root(LLVM.operands(v)[1], depth + 1)
    end
    return nothing
end

# Same-base gate: EVERY use of the memdata ptrtoint `pt` must be a `sub i64`
# whose sibling operand is a ptrtoint of a SAME-ROOT memdata pointer. A ptrtoint
# with NO uses (`saw == false`), or any use that is not such a same-root sub,
# means the base does not provably cancel → reject (the bennettvm-90l hazard).
function _verify_memdata_bounds_cluster(pt::LLVM.Instruction, src)::Bool
    root = _memdata_root(src)
    root === nothing && return false
    saw = false
    for u in LLVM.uses(pt)
        saw = true
        usr = LLVM.user(u)
        (usr isa LLVM.Instruction && LLVM.opcode(usr) == LLVM.API.LLVMSub) || return false
        ops = LLVM.operands(usr)
        length(ops) == 2 || return false
        sib = ops[1].ref == pt.ref ? ops[2] : ops[1]
        (sib isa LLVM.Instruction && LLVM.opcode(sib) == LLVM.API.LLVMPtrToInt) || return false
        _memdata_root(LLVM.operands(sib)[1]) == root || return false
    end
    return saw
end

# ============================================================================
# ---- Bennett-foz5 / CW-D: the CONFINED-VALUE contract (ADR 0017 §4a) ----
# ============================================================================
#
# THE SHAPE THIS EXISTS FOR (xkl frontier wall 7). Julia's `@boundscheck`
# cluster under `--check-bounds=yes` for a CLOSURE-CAPTURED `MemoryRef`
# (`_growend!` `%idxend41`) computes a pointer difference across the two halves
# of a SPLIT ref — codegen puts the `.ptr_or_offset` half inline in the closure
# environment struct and hoists the GC-tracked `.mem` half into the roots array:
#
#   %mem   = load ptr, (gep i8 %".roots.#self#", 16)   ; the .mem half
#   %d     = load ptr, (gep inbounds i8 %"#self#", 56) ; the .ptr_or_offset half
#   %e     = getelementptr i8, ptr %d, i64 %byteoff
#   %mdata = load ptr, (gep {i64,ptr} %mem, 0, 1)      ; _memdata_root == %mem
#   %s     = sub i64 (ptrtoint %e), (ptrtoint %mdata)  ; ROOTS ARE DISJOINT
#   %c     = icmp ult i64 %s, %bytelen
#   br i1 (%c & !%ovflw), %idxend62, %oob              ; %oob = throw + unreachable
#
# WHY Bennett-583s CANNOT BE WIDENED TO COVER IT. 583s's base-cancellation
# proof IS syntactic root equality (`_verify_memdata_bounds_cluster` demands
# `_memdata_root(sib) == root`). Here the two operands descend from two
# DIFFERENT function `Argument`s with no SSA edge between them. The only
# in-body witness pairing them is a `insertvalue {ptr,ptr}` that is DEAD — it
# survives solely because extraction mandates `optimize=false`, so building a
# soundness gate on it is a direct Rule 5 violation. The alternative witness is
# the byte-offset convention ("closure field +56 is field 0 of the captured
# ref; roots slot +16 is its field 1"), which is exactly the Julia ABI/codegen
# layout class Rule 5 forbids. And the fact itself is CROSS-FUNCTION: it
# depends on how the CALLER materialised the ref. Julia does not even assume
# the halves agree — the `%L84` `ConcurrencyViolationError` guard in this very
# body exists to compare them. There is no extraction-local oracle-match proof,
# and there never will be.
#
# ALSO NOT DONE, DELIBERATELY: extending `_memdata_root` to a new ROOT shape.
# Probe `p07_steal.jl` measured that doing so makes the 583s arm CLAIM jbko's
# `%L84` corpus witness (whose use is an `icmp eq`, so 583s's cluster gate then
# fails and 583s ERRORS) — regressing the chain to a wall EARLIER than wall 7.
# This arm is gated on the ptrtoint's USE SHAPE, never on its source provenance,
# which makes that steal STRUCTURALLY IMPOSSIBLE rather than merely absent: (C1)
# demands every use be a `sub`, `_jbko_identity_use_violation` demands every use
# be an `icmp eq`/`ne`, and a non-empty use set cannot satisfy both. Arm order
# is therefore not load-bearing between foz5 and jbko (it still is for the four
# advanced wall markers — do not reorder).
#
# THE SECOND PROOF (weaker than oracle match, and PROVED rather than assumed).
# `_foz5_confined_dead_bounds` establishes that the coerced value's ENTIRE
# influence on the program is a dead-throw branch condition:
#
#   (C0) the SOURCE pointer is a CERTIFIED MATERIALISED CELL — `_foz5_cert_src_kind`
#        — and is a named, non-suppressed instruction;
#   (C1) `pt` has >= 1 use and EVERY use is a 2-operand i64 `sub` whose sibling
#        operand is itself a `ptrtoint`;
#   (C2) each such `sub` has >= 1 use and EVERY use is an `icmp`;
#   (C3) the transitive i1 use-closure of each such `icmp` contains only i1
#        `and`/`or`/`xor` (each with >= 1 use) and CONDITIONAL `br`s consuming
#        the value as their CONDITION operand, and every such `br` has at least
#        one successor in the Bennett-utzc pruned dead-block set.
#
# THEOREM. Let `τ` be the extracted values transitively derived from `pt`
# through (C1)-(C3). By construction no member of `τ` is stored, returned,
# `inttoptr`ed, `zext`ed, `select`ed on, or `phi`'d, so the ONLY consumers of
# `τ` outside `τ` are the conditional `br`s of (C3): `τ` influences execution
# solely through the successor choice there. Take such a `br c, %T, %F` with
# (wlog) `%F` in the dead set. The pruner empties `%F` and gives it
# `IRBranch(:__unreachable__)` (`module_walk.jl`), which BennettVM materialises
# as a loud halt. If NATIVE takes `%T`: either the extracted condition agrees
# (trajectories coincide — everything outside `τ` is computed by the
# pre-existing, already-sound model) or it does not, and the extracted program
# HALTS LOUDLY. If NATIVE takes `%F`: `%F` is `unreachable`-terminated and
# `_assert_dead_block_is_throw_skeleton` has proved it a throw-family skeleton,
# so native THROWS and has no return value. ∎
#
#   >>> GUARANTEE: for every input on which NATIVE RETURNS A VALUE, the
#   >>> extracted program returns the SAME value or HALTS at the
#   >>> `:__unreachable__` sink. (ADR 0017 §4a.)
#
# WHAT IS *NOT* GUARANTEED — READ THIS BEFORE REUSING THE ARM. The theorem says
# nothing about the native-THROWS column: the throw may be MISSED, and on the
# native-returns column the halt may be SPURIOUS. Neither direction is
# authorised; both are UNBOUNDED by the theorem. ADR 0017 §4a records this as a
# downgrade of Decision-item-4's "faithful reversible throw" from PROVED to
# UNPROVED for confined guards. Do NOT read "oracle match or loud halt" as
# "oracle match": that misreading is the arm's chief hazard, and gate (B) of
# `test/test_foz5_confined_bounds.jl` is its executable refutation.
#
# WHY THIS IS NOT Bennett-lbot. lbot rules (shipped message, ~line 3417) that a
# "placeholder-0 would route away from the throw the native code takes and is
# UNSOUND". That ruling stands and is REAFFIRMED here: this arm FABRICATES
# NOTHING. It admits an OPERAND as the same cell identity 583s emits, and the
# compare, the i1 algebra and the branch are all emitted verbatim by the generic
# paths — the guard bit is still COMPUTED, from real in-model cells. Emitting a
# zero cell (or eliding the cluster) to make the guard provably weaker would be
# lbot's harm class, made worse by measurement: BennettVM has no region table
# and three monotone cursors (`bennettvm-pdqx`), so a missed bounds throw is an
# UNDETECTABLE adjacent-allocation clobber, and ADR 0018 §E defines an unstored
# load as 0. That route was proposed, adjudicated and REJECTED — see
# `docs/design/foz5/proposal_B.md` and the worklog.
#
# VALIDATION DEBT (disclosed). No runtime evidence about either unproven
# direction can exist until wall 8 clears, because the corpus still walls in the
# ROOT body before BennettVM can execute it: bead **Bennett-bvmd**. What IS
# measured: BennettVM stamps the Julia tier BYTE-granular (`_byte_cells`,
# `BennettVM/src/ir/intrinsics.jl`) and a byte GEP lowers to `IRVarGEP(_,_,_,8)`,
# so `D_vm - M.data_vm` is byte-exact whenever the closure slot was written by
# extracted code — i.e. the unprovable premise is EXPECTED to hold in the closed
# world. Expected is not proved; the contract claims only the theorem.
#
# COUPLING (see also `vector_vm_cfg.jl`): (C3) consumes the `dead_blocks` set
# THREADED FROM `module_walk.jl`, which is the very set the utzc pruner empties.
# Never re-derive "terminator is unreachable" locally — the two must stay one
# set by construction, not by agreement.

const _FOZ5_I1ALG = (LLVM.API.LLVMAnd, LLVM.API.LLVMOr, LLVM.API.LLVMXor)
const _FOZ5_DEPTH = 8          # the `_memdata_root` / `_param_ptr_root_ref` idiom
const _FOZ5_CLOSURE_CAP = 32   # i1-closure size cap (surprise guard, Rule 1)

_foz5_is_i1(v)::Bool = (t = LLVM.value_type(v);
                        t isa LLVM.IntegerType && LLVM.width(t) == 1)

# (C0) Is `v` a pointer SSA the walk PROVABLY materialises as one 64-bit cell?
#
# A POSITIVE WHITELIST, never an "is a pointer" test. Three admitted producers,
# each of which emits a node that DEFINES the cell:
#
#   * `load` of a pointer      -> `IRLoad(_, _, 64)`      (the Bennett-ares arm)
#   * `extractvalue` of a StructType pointer field -> `_struct_field_widths`
#                                 stamps 64 ("a pointer is one Int64 VM cell")
#   * `getelementptr`          -> `IRPtrOffset` / `IRVarGEP` (measured: a byte
#                                 GEP emits `IRVarGEP(_,_,_,8)`)
#
# READ THE EXACT DEPTH DISCIPLINE — it differs per arm, deliberately, and the
# ADR text is written to match it (foz5 hostile review D2):
#
#   * **`getelementptr`: RECURSIVE ON THE BASE.** A GEP's emitted node is an
#     OFFSET from its base operand, so the GEP is only a materialised cell if
#     its base is. The walk therefore follows the base chain to its ROOT and
#     requires the root to be certified in turn. This is what refuses a
#     PointerType `phi`/`select` (below) with a GEP interposed — WITHOUT the
#     recursion, `%pg = getelementptr i8, ptr %ph, i64 %off` bypasses the
#     sentinel refusal with ONE instruction (hostile-review fixtures B1 / C6,
#     both ADMITTED pre-fix). It also refuses a `GlobalVariable`-rooted GEP
#     (fixture B3), whose base is a global symbol rather than a cell.
#     INDEX CONSTNESS IS NOT REQUIRED, unlike `_p06b_slot_key`'s canonicalising
#     walk: the corpus's own element GEP has a VARIABLE index
#     (`getelementptr i8, ptr %d, i64 %bo`), and the index is irrelevant here —
#     the sentinel question is about the BASE, not the displacement.
#
#   * **`load`: DEPTH-0 ON PURPOSE, and this is a real scope boundary.** The
#     VALUE a load produces is a FRESH materialised cell (`IRLoad(dest, …, 64)`
#     defines `dest`) no matter where its ADDRESS came from. So a load through
#     a sentinel-valued address — `%pg = load ptr, ptr %ph` with `%ph` a ptr
#     `phi` (fixture B2) — is still admitted here, and foz5 adds NOTHING to
#     that hazard: the `IRLoad` reading the never-materialised address cell is
#     emitted by the LOAD ARM whether or not any `ptrtoint` follows. **The
#     address-sentinel question belongs to the load arm, not to this
#     predicate.** foz5's own theorem caps the consequence for the coerced
#     value at a wrong branch choice, i.e. at a loud halt. Pinned as a
#     KNOWN-ADMITTED gate (B2) rather than hidden.
#     One thing the load arm does NOT cover, so it is refused HERE: a `load`
#     whose POINTER OPERAND is a `GlobalVariable`. The bennettvm-416r.13 /
#     CW-D3 Lever 2 singleton-data alias arm (~line 5080) intercepts
#     `load ptr, ptr @"jl_global#N"`, emits **NO IRInst at all**, and instead
#     ALIASES the load-result name to the global symbol. Such a load is
#     "registered" but never materialised as a cell, and `_p06b_suppressed_refs`
#     does not contain it (that set holds only sret boxes), so neither the
#     `haskey(names, …)` nor the `suppressed_refs` check in (C0) catches it.
#     Pre-fix, fixtures C1/C2 emitted `IRBinOp(:or, SSAOperand(:jl_global#77),
#     0, 64)` — an `:or` identity over a GLOBAL BASE SYMBOL. Refused by the
#     three lines below; pinned by gates (C1)/(C2).
#
# EVERYTHING ELSE IS REFUSED. The load-bearing refusal is the PointerType
# `phi`/`select`: it carries the Bennett-cc0 M2b WIDTH-0 SENTINEL — its routing
# is recorded in `ptr_provenance` at LOWERING time rather than as a value — so
# coercing one emits an `:or` identity over a cell that was NEVER MATERIALISED.
# The confinement theorem would cap the damage at a halt, but that class is a
# SILENT miscompile and Rule 1 prefers a conservative loud reject to an
# unverified admission. Pinned by gates (N) direct, (B1)/(C6) via a GEP.
#
# NOT `_jbko_cell_ptr_src_kind`: that whitelist is `load`/`extractvalue` only
# and would refuse the corpus's `getelementptr`-sourced element half. The two
# lists are deliberately different sizes for deliberately different contracts.
function _foz5_cert_src_kind(v, depth::Int=0)::Symbol
    depth > _FOZ5_DEPTH && return :none
    v isa LLVM.Instruction || return :none           # Argument / GlobalVariable / const
    ty = LLVM.value_type(v)
    ty isa LLVM.PointerType || return :none
    LLVM.addrspace(ty) == 0 || return :none          # addrspace-0 only (cf. 7wsz)
    opc = LLVM.opcode(v)
    if opc == LLVM.API.LLVMLoad
        # The 416r.13 singleton-data alias arm emits nothing for this shape.
        LLVM.operands(v)[1] isa LLVM.GlobalVariable && return :none
        return :load
    elseif opc == LLVM.API.LLVMExtractValue
        return LLVM.value_type(LLVM.operands(v)[1]) isa LLVM.StructType ?
               :extractvalue : :none
    elseif opc == LLVM.API.LLVMGetElementPtr
        # A GEP is an OFFSET from its base — certified only if the base is.
        return _foz5_cert_src_kind(LLVM.operands(v)[1], depth + 1) === :none ?
               :none : :gep
    end
    return :none                                     # phi / select / call / ...
end

# (C3) Does the i1 value `v` reach ONLY dead-edge conditional branches, through
# i1 algebra only? The generic "this i1 steers nothing but a dead-throw branch"
# walker — Bennett-sku0's candidate fix (b) is this predicate verbatim, so name
# and document it generically rather than as a foz5 private (CLAUDE.md §12).
#
# POLARITY-AGNOSTIC BY CONSTRUCTION: it asks whether SOME successor is dead, and
# never reads `LLVM.successors(br)[2]` as "the false target". A design that
# depends on that operand-order convention has an undeclared LLVM.jl API
# premise; this one does not. Pinned GREEN by gate (B2).
#
# Conservative in every direction: a use-less i1 is `false` (a value that steers
# nothing is evidence the walker's picture is incomplete — the 583s `saw`
# discipline); an unconditional `br`, a `select`, a `zext`, a `phi`, a `switch`,
# a `call`, a `store`, a `ret` are all outside the whitelist and REJECT. Drift
# in the emitted i1 algebra therefore degrades to the EXISTING loud wall, never
# to a silent admission.
function _foz5_i1_confined(v, dead_blocks::Set{_LLVMRef},
                           seen::Set{_LLVMRef}, depth::Int=0)::Bool
    depth > _FOZ5_DEPTH && return false
    length(seen) > _FOZ5_CLOSURE_CAP && return false
    v isa LLVM.Instruction || return false
    _foz5_is_i1(v) || return false
    v.ref in seen && return true                     # already proved on this walk
    push!(seen, v.ref)
    saw = false
    for u in LLVM.uses(v)
        saw = true
        usr = LLVM.user(u)
        usr isa LLVM.Instruction || return false
        uopc = LLVM.opcode(usr)
        if uopc == LLVM.API.LLVMBr
            (usr isa LLVM.BrInst && LLVM.isconditional(usr)) || return false
            # The value must be the CONDITION, not (defensively) anything else.
            LLVM.condition(usr).ref == v.ref || return false
            any(s -> s.ref in dead_blocks, LLVM.successors(usr)) || return false
        elseif uopc in _FOZ5_I1ALG
            _foz5_is_i1(usr) || return false
            _foz5_i1_confined(usr, dead_blocks, seen, depth + 1) || return false
        else
            return false
        end
    end
    return saw
end

# (C0)+(C1)+(C2)+(C3). The whole confined-value predicate for a `ptrtoint`.
# PURE: no mutation of `names` / `suppressed_refs` / `dead_blocks`, so the arm
# may call it in both its entry condition and its admission condition and get
# the same answer — which is why foz5 introduces NO fall-through into the jbko
# arm and the a8nw ordering note stays literally true.
function _foz5_confined_dead_bounds(pt::LLVM.Instruction,
                                    names::Dict{_LLVMRef, Symbol},
                                    suppressed_refs::Set{_LLVMRef},
                                    dead_blocks::Set{_LLVMRef})::Bool
    isempty(dead_blocks) && return false             # no sink ⇒ nothing to confine
    src = LLVM.operands(pt)[1]
    # (C0) certified, materialised, emitted.
    _foz5_cert_src_kind(src) === :none && return false
    src isa LLVM.Instruction || return false
    haskey(names, src.ref) || return false
    src.ref in suppressed_refs && return false
    saw = false
    for u in LLVM.uses(pt)
        saw = true
        usr = LLVM.user(u)
        # (C1) every use is a 2-operand i64 `sub` of two ptrtoints. The WIDTH
        # check is load-bearing, not decoration (hostile review D3): the arm's
        # own width guard covers the ptrtoint's result, not the `sub`'s, so a
        # `trunc`-then-`sub i32` cluster would otherwise satisfy the prose while
        # differencing truncated cell values. It also keeps the predicate safe
        # for the Bennett-sku0 reuse, which will call it on shapes this corpus
        # never produces.
        (usr isa LLVM.Instruction && LLVM.opcode(usr) == LLVM.API.LLVMSub) || return false
        let st = LLVM.value_type(usr)
            (st isa LLVM.IntegerType && LLVM.width(st) == 64) || return false
        end
        ops = LLVM.operands(usr)
        length(ops) == 2 || return false
        sib = ops[1].ref == pt.ref ? ops[2] : ops[1]
        (sib isa LLVM.Instruction &&
         LLVM.opcode(sib) == LLVM.API.LLVMPtrToInt) || return false
        # (C2) every use of the `sub` is an `icmp`, and (C3) each icmp's i1
        # closure lands only on dead-edge branches.
        sub_saw = false
        for su in LLVM.uses(usr)
            sub_saw = true
            susr = LLVM.user(su)
            (susr isa LLVM.Instruction &&
             LLVM.opcode(susr) == LLVM.API.LLVMICmp) || return false
            _foz5_i1_confined(susr, dead_blocks, Set{_LLVMRef}()) || return false
        end
        sub_saw || return false
    end
    return saw
end

# ---- Bennett-57hd / CW-D: VALUE-IDENTITY ptrtoint (ADR 0017 §4b) ------------
#
#   %f0   <- load (gep {ptr,ptr} %obj, 0, 0)   ; array.ref.ptr_or_offset
#   %f1   <- load (gep {ptr,ptr} %obj, 0, 1)   ; array.ref.mem
#   %md2  <- load (gep {i64,ptr} %f1,  0, 1)   ; array.ref.mem.data
#   %d    =  sub(ptrtoint %f0, ptrtoint %md2)  ; Julia's `memoryrefoffset`
#   %idx  =  udiv exact %d, 8                  ; ...as an ELEMENT INDEX
#
# ============================================================================
# THE THIRD PROOF — AND IT IS THE STRONGEST OF THE THREE, NOT THE WEAKEST
# ============================================================================
#
# WHY A THIRD CONTRACT AT ALL. Bennett-583s declines because `_memdata_root`
# establishes base cancellation by SYNTACTIC SSA EQUALITY of the two `.data`
# loads; here the two operands are the two halves of ONE `MemoryRef`, both read
# out of one freshly `julia.gc_alloc_obj`-ed `Array` header, related through an
# aggregate store and a same-slot reload rather than through one SSA name.
# Bennett-foz5 / §4a declines CORRECTLY: its clause (iii) requires every use of
# the `sub` to be an `icmp`, and this difference's sole use is the `udiv`. The
# value then ESCAPES — into a live grow-or-not branch and into two closure-env
# slots that `_growend!` reads as `jl_alloc_genericmemory_unchecked`'s
# ALLOCATION SIZE and `llvm.memmove`'s LENGTH. Under the arena model
# (`bennettvm-pdqx`: no region table, three monotone cursors; ADR 0018 §E: an
# unstored load reads 0) a wrong allocation size is an UNDETECTABLE
# adjacent-allocation clobber. THERE IS NO CONFINEMENT AVAILABLE FOR THIS SHAPE
# AND §4a MUST NOT BE WIDENED TO REACH IT.
#
# THE PREDICATE. `_57hd_value_identity_cluster` establishes:
#
#   (V0) the SOURCE pointer is a CERTIFIED CELL PRODUCER — `_foz5_cert_src_kind`
#        (verbatim reuse of §4a clause (i)) — and is a named, non-suppressed
#        instruction;
#   (V1) `pt` has >= 1 use and EVERY use is a 2-operand i64 `sub` whose sibling
#        operand is itself a `ptrtoint` of a source also satisfying (V0);
#   (V2) for every such sibling, the two sources lie in ONE BASIC BLOCK and
#        `_57hd_canon` reduces them to the SAME canonical value;
#   (V3) every store `_57hd_canon` forwards through targets a P06B-CERTIFIED
#        CELL POINTER (`_p06b_cell_ptr_target_kind`), so the copy step the walk
#        reasons about is one the EXTRACTION MATERIALISES.
#
# THEOREM. Let `φ` be ANY map from native addresses to BennettVM pointer-cell
# values — injective or not, affine or not, byte-scaled or not. By (V2) the two
# sources denote ONE pointer value `p` on every execution that reaches the
# `sub`: `_57hd_canon`'s only inference steps are (i) "the value loaded from
# slot `k` equals the value the uniquely-reaching store wrote into slot `k`" and
# (ii) "two loads of slot `k` with no intervening writer to `k` return the same
# value", both of which are statements about VALUES, valid in straight-line
# code. Natively the `sub` evaluates `p − p = 0`. In BennettVM the two coercions
# read two cells that (V3) guarantees were materialised and that (V2)
# guarantees hold one and the same value `φ(p)`, so the `sub` evaluates
# `φ(p) − φ(p) = 0`. THE TWO AGREE FOR EVERY `φ`. ∎
#
#   >>> GUARANTEE: the admitted cluster computes, on every input, the SAME
#   >>> INTEGER the native program computes. Decision item 4's "faithful
#   >>> reversible throw" is RETAINED UNCHANGED for every guard downstream of
#   >>> this admission; ADR 0017 §4a's conditionality clause is NOT invoked.
#
# WHERE THIS SITS AMONG THE THREE POINTER CONTRACTS — the one-line answer to
# "which oracle argument?", and the reason this one composes rather than
# negotiates:
#
#   | contract      | the invariance it needs of `φ`                     |
#   |---------------|----------------------------------------------------|
#   | Bennett-583s  | affine with slope 1 WITHIN ONE ALLOCATION           |
#   | Bennett-jbko  | INJECTIVE (`eq`/`ne` survives relabelling)          |
#   | Bennett-57hd  | ** NONE — `0 = 0` for any `φ` whatsoever **         |
#   | Bennett-foz5  | n/a — declines oracle match; confines instead       |
#
# BOTH COLUMNS OF THE FAILURE MATRIX ARE BOUNDED, and that is the whole point:
#
#   | | native RETURNS            | native THROWS                            |
#   |-|---------------------------|------------------------------------------|
#   |admit| same value            | same branch at every downstream guard —  |
#   |     |                       | operands are oracle-exact, so item 4's   |
#   |     |                       | PROVED-faithful throw, not §4a's         |
#   |decline| the existing loud wall | the existing loud wall                |
#
# §4a's banner has to say "the throw may be MISSED, and the halt may be
# SPURIOUS; neither direction is authorised; both are UNBOUNDED by the theorem."
# THIS ARM HAS NO SUCH PARAGRAPH. The residual risk is NOT in the theorem — it
# is in the ANALYSIS: if `_57hd_canon` ever returns "same value" for two
# different values the hypothesis is false. Everything below is therefore
# written FAIL-CLOSED, and every premise is READ FROM LLVM'S OWN ATTRIBUTES
# rather than from a table of callee names.
#
# COMPOSITION (why §4a's conditionality is SATISFIED, not voided). §4a's
# theorem is stated relative to "everything outside `τ` is computed by the
# pre-existing, already-sound model" (see the foz5 block above). A §4b
# admission is an ORACLE-MATCH admission, so the admitted producer BELONGS TO
# that model and no clause of §4a is invoked. Bennett-jbko's
# trajectory-correspondence argument is preserved BY CONSTRUCTION: the
# grow-or-not branch is decided by an oracle-exact index, so the allocation
# sizes derived from it — and hence `arena_top`, and hence every subsequent
# pointer cell value — are provably the native ones. Had this value been
# admitted under a DECLARED premise instead, §4a's and jbko's guarantees would
# both have become conditional on that declaration.
#
# FIRST REFUSAL: 583s, then §4a, then this. `_memdata_root` is NOT touched
# (`p07_steal.jl` measured that widening it makes the 583s arm claim jbko's
# `%L84` witness and then ERROR). The non-steal is STRUCTURAL and measured over
# both corpus bodies: this predicate is false on both 583s clusters and on all
# three §4a clusters, and it CANNOT fire on jbko's witness because (V1) demands
# every use be a `sub` while `_jbko_identity_use_violation` demands every use be
# an `icmp eq`/`ne`, and a non-empty use set cannot satisfy both.
#
# NON-GOAL, MEASURED AND REJECTED — READ BEFORE "IMPROVING" THIS. The natural
# generalisation (`α_k`) strips `getelementptr i8` chains, canonicalises the
# BASES and concludes `sub ≡ Σ displacements`. Measured over both corpus
# bodies, it CLAIMS `%L46` and `%L58` — both clusters Bennett-583s owns — and
# gains ZERO new clusters, because what blocks the other two is the CALL, not
# the displacement. It also re-acquires 583s's residual byte-tier dependence,
# deleting the "no representation premise" property that is this contract's
# entire case. DISPLACEMENT ZERO IS THE DESIGN, not a limitation accepted
# grudgingly. Pinned by gate (S) of `test/test_57hd_value_identity.jl`.
#
# ALSO REJECTED: route δ′, a same-`MemoryRef` provenance-pair predicate resting
# on the DECLARED Julia language invariant "field 0 points into field 1's data
# region". It covers nothing this does not (the `%L21`/`%L43` clusters it was
# scoped around are ALREADY ADMITTED by the shipped §4a predicate — measured,
# gate (S)), its failure mode is a silently wrong heap rather than a halt, and
# it amplifies `bennettvm-jb6w` by recognising an unnamed literal `{ptr,ptr}` as
# "a MemoryRef". THIS ARM HAS NO TYPE-SHAPE RECOGNISER AT ALL — it asks only
# "are these the same value?", a question with the same correct answer on every
# language tier. Gates (H)/(H2) pin both directions.
#
# DECLARED PREMISES (the A-ledger; the ADR carries the same three):
#   (P1) LLVM attributes in the input module are TRUTHFUL. An IR-WELL-FORMEDNESS
#        premise, the same class as "the `Sub` opcode means subtraction" — NOT
#        the ABI/codegen-layout class Rule 5 forbids. A false `noalias` or
#        `memory(…)` would miscompile under LLVM's own optimiser. A MISSING
#        attribute always REJECTS. Measured load-bearing: reclassify the
#        allocator as unknown-effect and the corpus lemma collapses.
#   (P2) `llvm.memcpy`/`memmove`/`memset` mean what LLVM says they mean,
#        identified BY NAME. The same premise the shipped Bennett-37mt /
#        Bennett-vau9 / Bennett-sy29 arms already make.
#   (P3) ADR 0018 §A cell-copy fidelity — a load/store/insertvalue copies a cell
#        value verbatim. PRE-EXISTING: the substrate Bennett-jbko already stands
#        on, and EXECUTABLE (`BennettVM/test/test_57hd_value_identity_vm.jl`).
#   (P4) LLVM.jl's instruction iteration over a basic block yields PROGRAM
#        ORDER. `seq` / `order` / `_57hd_predates` are all built from it, so a
#        reordering iterator would silently invert "before" and "after". An
#        LLVM.jl API premise, not a Julia one, and shared with every positional
#        walker in this file.
#   (P5) The VM transport of rule (b) — "two loads of one slot with no writer
#        between return the same cell value" — follows INDUCTIVELY, not by
#        assumption: the base case is SSA ref equality (the same node, hence the
#        same cell), and each store-forward hop is (V3)-certified, i.e. the
#        store it forwards through is one the extraction materialises as cells,
#        so the copy the native world performs is a copy the VM performs too.
#
# O-1 (drift risk, mitigated rather than disclosed-and-left). The `memory`
# attribute's value is a RAW PACKED INTEGER whose encoding is LLVM-internal and
# NOT a stable API (Rule 5). `_57hd_writes_no_ir_memory` therefore FAILS CLOSED
# on any bit outside the three locations this LLVM version defines, and gates
# (D2)/(D3) of the owning test are decode CANARIES that must move in OPPOSITE
# directions — a decoder that fails closed on everything fails (D3); a decoder
# that reads "writes nothing" for everything fails (D2). The same two-step
# call-site-then-declaration fallback covers `nocapture`'s eventual respelling
# as `captures(none)`; absence is always `false`, which is the safe direction.
#
# COUPLING: this arm CONSUMES `_p06b_slot_key` (the canonical `(root, byte
# offset)` address key — the p06b N2 hostile-review fix), `_root_scale` (bvmd's
# byte-tier predicate) and `_p06b_cell_ptr_target_kind` (p06b's (P4) target
# certification). All three are shipped single-sources-of-truth with large
# owning suites; a change to any of them lands here.

const _57HD_DEPTH        = 8    # the `_memdata_root` / `_FOZ5_DEPTH` idiom
const _57HD_SCAN_CAP     = 512  # instructions inspected per cluster (Rule 1)
const _57HD_ESCAPE_DEPTH = 4    # `alloca` non-escape GEP recursion
# LLVM 18 MemoryEffects: 3 locations (ArgMem=0, InaccessibleMem=1, Other=2) x
# 2 bits (NoModRef=0, Ref=1, Mod=2, ModRef=3). ANY bit outside this mask means
# the encoding has drifted ⇒ fail closed (O-1).
const _57HD_ME_KNOWN_MASK = 0b111111
const _57HD_ME_MOD        = 2

# LLVM's attribute-kind ids are looked up BY NAME on every call rather than
# cached in a `const`: a `const` would be evaluated at PRECOMPILE time and
# serialised into the `.ji`, baking one LLVM build's numbering into the package
# (Rule 5). The lookup is a static-table probe.
_57hd_attr_kind(nm::String)::UInt32 =
    LLVM.API.LLVMGetEnumAttributeKindForName(nm, Csize_t(length(nm)))

const _57HD_FN_ATTR_IDX = reinterpret(UInt32, Int32(-1))   # LLVMAttributeFunctionIndex
const _57HD_RET_ATTR_IDX = UInt32(0)                       # LLVMAttributeReturnIndex

# Read an enum attribute at `idx` from the CALL SITE, falling back to the CALLEE
# DECLARATION.
#
# > PROSE-VS-PREDICATE TRAP, MEASURED TWICE (independently, by both proposers).
# > A CALL-SITE-ONLY CHECK REJECTS THE CORPUS. `llvm.memcpy` / `llvm.memset`
# > carry `nocapture` on the DECLARATION's parameter
# > (`declare void @llvm.memcpy.p0.p0.i64(ptr noalias nocapture writeonly, …)`)
# > and NOT at the call site, and the corpus scan window contains
# > `memcpy(%"new::Array.size", %"new::Array.size_ptr1", 8)` whose destination
# > root is exactly such an `alloca`. The same is true of `memory` on all three
# > mem intrinsics. Say "call site OR callee declaration" — never "the call
# > site". Pinned by gate (F2).
function _57hd_call_attr(call::LLVM.Instruction, idx::UInt32, nm::String)
    k = _57hd_attr_kind(nm)
    k == 0 && return C_NULL                     # unknown to this LLVM ⇒ absent
    a = LLVM.API.LLVMGetCallSiteEnumAttribute(call, idx, k)
    a != C_NULL && return a
    co = LLVM.called_operand(call)
    co isa LLVM.Function || return C_NULL
    return LLVM.API.LLVMGetEnumAttributeAtIndex(co, idx, k)
end

# The callee's MemoryEffects, or `nothing` when no `memory` attribute is
# retrievable at all (⇒ `:unknown` ⇒ the walk stops). `julia.get_pgcstack`
# carries NO attribute group whatever and lands here, deliberately: this arm
# refuses to ASSERT that it writes nothing.
#
# OPERAND BUNDLES ARE INVISIBLE TO THE RAW ATTRIBUTE, so a call carrying ANY
# bundle is `:unknown` regardless of what `memory` says. LLVM's own
# `CallBase::getMemoryEffects()` ORs in `writeOnly()` for a clobbering bundle;
# reading the attribute alone therefore believes a truthful `memory(none)`
# declaration about a call that LLVM itself treats as a writer. Measured
# (hostile-review probe `probe5.jl` R1): `@vi_pure` declared `memory(none)`,
# called with a `[ "jl_roots"(ptr %junk) ]` bundle, was ADMITTED — contradicting
# ADR 0017 §4b's "every unmodelled effect terminates the analysis
# unsuccessfully" verbatim. Corpus-neutral: zero bundle sites in either body.
# Pinned by gate (D4).
function _57hd_mem_effects(call::LLVM.Instruction)::Union{Nothing, Int}
    LLVM.API.LLVMGetNumOperandBundles(call) == 0 || return nothing
    a = _57hd_call_attr(call, _57HD_FN_ATTR_IDX, "memory")
    a == C_NULL && return nothing
    return Int(LLVM.API.LLVMGetEnumAttributeValue(a))
end

# Does the callee provably write NO IR-VISIBLE memory? `inaccessiblemem` is by
# definition not visible to this analysis, so only ArgMem and Other matter.
# FAIL-CLOSED on an unrecognised encoding (O-1).
function _57hd_writes_no_ir_memory(me::Int)::Bool
    (me & ~_57HD_ME_KNOWN_MASK) == 0 || return false          # O-1
    ((me >> 0) & _57HD_ME_MOD) == 0 && ((me >> 4) & _57HD_ME_MOD) == 0
end

_57hd_writes_other(me::Int)::Bool =
    (me & ~_57HD_ME_KNOWN_MASK) != 0 || ((me >> 4) & _57HD_ME_MOD) != 0

_57hd_has_noalias_ret(call::LLVM.Instruction)::Bool =
    _57hd_call_attr(call, _57HD_RET_ATTR_IDX, "noalias") != C_NULL

# (A4) NON-ESCAPING `alloca`: one whose pointer is only ever DEREFERENCED (a
# load/store ADDRESS operand), const-GEP'd, or passed at a `nocapture`
# parameter position. Such an object cannot be aliased by any pointer not
# syntactically derived from it. Attribute-checked, never name-matched.
#
# ┌──────────────────────── THE STORE ARM HAS TWO HALVES ────────────────────┐
# │ CHECKING ONLY THE ADDRESS OPERAND IS A P0 FAIL-OPEN, AND IT WAS EXECUTED.│
# │ `store ptr %a, ptr %a` writes the alloca's OWN ADDRESS into itself. The  │
# │ address half passes, so `%a` was reported NON-ESCAPING; the reloaded     │
# │ copy `%p = load ptr, ptr %a` classifies `:other`, so                     │
# │ `_57hd_roots_disjoint(%a, %p)` returned TRUE and a later                 │
# │ `store ptr %junk, ptr %a` — a write straight through the alias — was     │
# │ SKIPPED by the clobber scan. Hostile-review probe `probe3_vm.jl` ran the │
# │ admitted cluster on BennettVM: **the `sub` evaluated to 64**, against an │
# │ ADR 0017 §4b guarantee of 0 in both worlds, and it escaped into a        │
# │ `gc_alloc_obj` size. The VALUE half below is what closes it. The GEP     │
# │ recursion covers the `store ptr %a, ptr (gep %a, k)` spelling, because   │
# │ the recursive call sees the same store with `%a` as its VALUE operand.   │
# │ Corpus-neutral: zero self-stores measured in either corpus body.         │
# │ Pinned by gate (C3).                                                     │
# └──────────────────────────────────────────────────────────────────────────┘
function _57hd_alloca_noescape(a::LLVM.Value, depth::Int=0)::Bool
    depth > _57HD_ESCAPE_DEPTH && return false
    for u in LLVM.uses(a)
        usr = LLVM.user(u)
        usr isa LLVM.Instruction || return false
        o = LLVM.opcode(usr)
        if o == LLVM.API.LLVMLoad
            LLVM.operands(usr)[1].ref == a.ref || return false
        elseif o == LLVM.API.LLVMStore
            sops = LLVM.operands(usr)
            sops[2].ref == a.ref || return false   # must be the ADDRESS ...
            sops[1].ref == a.ref && return false   # ... and NEVER the VALUE
        elseif o == LLVM.API.LLVMGetElementPtr
            LLVM.operands(usr)[1].ref == a.ref || return false
            _57hd_alloca_noescape(usr, depth + 1) || return false
        elseif o == LLVM.API.LLVMCall
            # OPERAND BUNDLES SHIFT THE OPERAND→PARAMETER INDEX MAPPING, so the
            # `nocapture` lookup below would consult the wrong parameter. A
            # bundle is also a capture channel in its own right. Fail closed.
            LLVM.API.LLVMGetNumOperandBundles(usr) == 0 || return false
            ops = LLVM.operands(usr)
            for i in 1:(length(ops) - 1)          # last operand is the callee
                ops[i].ref == a.ref || continue
                _57hd_call_attr(usr, UInt32(i), "nocapture") != C_NULL || return false
            end
        else
            return false
        end
    end
    return true
end

# Object classification for the disjointness test. `:other` covers everything
# the analysis cannot name — a pointer loaded from a global, an `Argument`, a
# `phi`. TWO `:other` ROOTS ARE NEVER TREATED AS DISJOINT.
function _57hd_obj_kind(r::_LLVMRef)::Symbol
    v = LLVM.Value(r)
    v isa LLVM.Instruction || return :other
    o = LLVM.opcode(v)
    o == LLVM.API.LLVMAlloca && return :alloca
    (o == LLVM.API.LLVMCall && _57hd_has_noalias_ret(v)) && return :noalias_call
    return :other
end

# FRESHNESS ORDER — load-bearing, and the reason a bare "`noalias` ⇒ disjoint
# from everything" rule is UNSOUND. A `noalias`-returning call names an object
# no PRE-EXISTING pointer can alias; it says nothing about a pointer derived
# from that object LATER. So `R` is disjoint from a fresh object `F` only when
# `R`'s definition PRECEDES `F`'s.
function _57hd_predates(r::_LLVMRef, f::LLVM.Value)::Bool
    v = LLVM.Value(r)
    v isa LLVM.Instruction || return true                # Argument / global / const
    LLVM.opcode(v) == LLVM.API.LLVMAlloca && return true  # entry-block storage
    f isa LLVM.Instruction || return false
    pv, pf = LLVM.parent(v), LLVM.parent(f)
    pv.ref == pf.ref || return false                      # cross-block: conservative
    for i in LLVM.instructions(pv)
        i.ref == v.ref && return true
        i.ref == f.ref && return false
    end
    return false
end

# The UNDERLYING object of an address, through address-forming casts and GEPs
# with ANY index (constant or not).
#
# LOAD-BEARING AGAINST A LATENT UNSOUNDNESS, found in review rather than in the
# corpus, so it is written down here rather than discovered later.
# `_p06b_slot_key` deliberately stops at a VARIABLE index and makes that GEP its
# own root — sound for the KEY (two runtime-indexed addresses cannot be proven
# equal), but a disaster for DISJOINTNESS if taken literally: a
# `getelementptr i8, ptr %a, i64 %i` store into a non-escaping `alloca %a` gets
# the GEP as its "root", and the `:alloca` + non-escape rule below would then
# declare that write DISJOINT FROM `%a` — i.e. skip a write straight into the
# tracked object. Two roots with the same underlying object are therefore never
# disjoint, whatever their spellings.
function _57hd_underlying(r::_LLVMRef, depth::Int=0)::_LLVMRef
    depth > _57HD_DEPTH && return r
    v = LLVM.Value(r)
    v isa LLVM.Instruction || return r
    o = LLVM.opcode(v)
    (o == LLVM.API.LLVMGetElementPtr || o == LLVM.API.LLVMBitCast ||
     o == LLVM.API.LLVMAddrSpaceCast) || return r
    ops = LLVM.operands(v)
    isempty(ops) && return r
    return _57hd_underlying(ops[1].ref, depth + 1)
end

function _57hd_roots_disjoint(a::_LLVMRef, b::_LLVMRef)::Bool
    a == b && return false
    ua, ub = _57hd_underlying(a), _57hd_underlying(b)
    ua == ub && return false          # same object, two spellings — NEVER disjoint
    ka, kb = _57hd_obj_kind(ua), _57hd_obj_kind(ub)
    (ka in (:alloca, :noalias_call) && kb in (:alloca, :noalias_call)) && return true
    ka === :alloca && _57hd_alloca_noescape(LLVM.Value(ua)) && return true
    kb === :alloca && _57hd_alloca_noescape(LLVM.Value(ub)) && return true
    ka === :noalias_call && return _57hd_predates(ub, LLVM.Value(ua))
    kb === :noalias_call && return _57hd_predates(ua, LLVM.Value(ub))
    return false
end

# The written byte ranges of one instruction, as `(root, lo, hi)` triples, or
# `:unknown`. FAIL-CLOSED: `:unknown` terminates the walk. Every opcode outside
# the no-write list — `invoke`, `atomicrmw`, `cmpxchg`, `fence`, `va_arg`, an
# unattributed `call` — lands in `:unknown`.
const _57HD_NOWRITE_OPS = Set([
    LLVM.API.LLVMLoad, LLVM.API.LLVMGetElementPtr, LLVM.API.LLVMAlloca,
    LLVM.API.LLVMAdd, LLVM.API.LLVMSub, LLVM.API.LLVMMul, LLVM.API.LLVMUDiv,
    LLVM.API.LLVMSDiv, LLVM.API.LLVMURem, LLVM.API.LLVMSRem, LLVM.API.LLVMShl,
    LLVM.API.LLVMLShr, LLVM.API.LLVMAShr, LLVM.API.LLVMAnd, LLVM.API.LLVMOr,
    LLVM.API.LLVMXor, LLVM.API.LLVMICmp, LLVM.API.LLVMPHI, LLVM.API.LLVMSelect,
    LLVM.API.LLVMTrunc, LLVM.API.LLVMZExt, LLVM.API.LLVMSExt,
    LLVM.API.LLVMPtrToInt, LLVM.API.LLVMIntToPtr, LLVM.API.LLVMBitCast,
    LLVM.API.LLVMAddrSpaceCast, LLVM.API.LLVMExtractValue,
    LLVM.API.LLVMInsertValue, LLVM.API.LLVMBr, LLVM.API.LLVMRet,
    LLVM.API.LLVMSwitch, LLVM.API.LLVMUnreachable, LLVM.API.LLVMFreeze,
])

function _57hd_write_footprint(i::LLVM.Instruction, dl)
    o = LLVM.opcode(i)
    if o == LLVM.API.LLVMStore
        ops = LLVM.operands(i)
        (r, off) = _p06b_slot_key(ops[2])
        w = Int(LLVM.storage_size(dl, LLVM.value_type(ops[1])))
        return Tuple{_LLVMRef, Int, Int}[(r, off, off + w)]
    elseif o == LLVM.API.LLVMCall
        me = _57hd_mem_effects(i)
        me === nothing && return :unknown            # no attribute ⇒ unknown
        _57hd_writes_no_ir_memory(me) && return Tuple{_LLVMRef, Int, Int}[]
        _57hd_writes_other(me) && return :unknown    # may write anything visible
        # An argmem-only writer with a KNOWN extent: exactly the three mem
        # intrinsics (P2). A VARIABLE length is `:unknown` — which is where the
        # Bennett-vau9 shape correctly lands.
        co = LLVM.called_operand(i)
        nm = co isa LLVM.Function ? LLVM.name(co) : ""
        if startswith(nm, "llvm.memcpy") || startswith(nm, "llvm.memmove") ||
           startswith(nm, "llvm.memset")
            ops = LLVM.operands(i)
            length(ops) >= 3 || return :unknown
            ops[3] isa LLVM.ConstantInt || return :unknown
            n = Int(_const_int_as_int(ops[3]))
            # A NEGATIVE length INVERTS the range: `[off, off+n)` with `n < 0`
            # is empty under the `h <= lo || l >= hi` non-overlap test, so every
            # real write it covers would be skipped. Today the Bennett-37mt arm
            # rejects such a memcpy before this runs — but THIS ARM MUST NOT
            # REST ITS OWN SOUNDNESS ON ANOTHER ARM'S GUARD. Gate (D6).
            n >= 0 || return :unknown
            (r, off) = _p06b_slot_key(ops[1])
            return Tuple{_LLVMRef, Int, Int}[(r, off, off + n)]
        end
        return :unknown
    end
    return o in _57HD_NOWRITE_OPS ? Tuple{_LLVMRef, Int, Int}[] : :unknown
end

# Is `[lo, hi)` of `root` written by any instruction STRICTLY BETWEEN positions
# `p1` and `p2` of the straight-line block `seq`? Conservative in every
# direction: an `:unknown` footprint clobbers; a root that is neither equal nor
# PROVABLY DISJOINT clobbers; and a SAME-ROOT non-overlap judgement is taken
# only at the BYTE TIER (`_root_scale == 1`), because a byte-range disjointness
# is a claim about VM CELLS and only the byte tier makes byte offsets BE cell
# offsets. That last gate is `bennettvm-jb6w` pre-empted rather than amplified.
#
# ┌──────── RAW vs CANONICAL ROOTS — THE INVARIANT, AND WHY IT IS SAFE ───────┐
# │ `root` arrives CANONICALISED (`_57hd_canon` resolved it through           │
# │ store-forwards and same-slot reloads), while every `r` in a footprint is  │
# │ a RAW `_p06b_slot_key` root. The two notions are deliberately NOT unified │
# │ — doing so would make `_57hd_canon` and `_57hd_clobbered` mutually        │
# │ recursive, materially enlarging the recursion graph of the arm's most     │
# │ delicate walker for no measured gain. The mismatch is safe because it can │
# │ only ever fail CLOSED, and that is a case analysis, not a hope:           │
# │                                                                          │
# │   * `_57hd_canon` returns its argument UNCHANGED for everything that is   │
# │     not a pointer-result `load`. So an `alloca` root, a `noalias`-call    │
# │     root, an `Argument` and a global are canonical == raw already, and    │
# │     the two `:alloca` / `:noalias_call` disjointness rules below see      │
# │     exactly the refs they would have seen anyway.                         │
# │   * The ONLY class where canonical ≠ raw is LOAD vs LOAD (two SSA names   │
# │     for one slot). `_57hd_underlying` does not strip loads, so both       │
# │     classify `:other`, `_57hd_roots_disjoint` returns FALSE for two       │
# │     `:other` roots by construction, the `r == root` equality then fails,  │
# │     and this function RETURNS TRUE — i.e. it reports a clobber and the    │
# │     admission is REFUSED. Losing a true admission is the safe direction.  │
# │                                                                          │
# │ Consequently no raw/canonical divergence can produce a FALSE `disjoint`   │
# │ or a FALSE `same-root non-overlap`. If a future change makes `_57hd_canon`│
# │ return an `alloca` or a call for a load-rooted address, THIS ARGUMENT     │
# │ BREAKS and the roots must be unified — say so here before doing it.       │
# └──────────────────────────────────────────────────────────────────────────┘
function _57hd_clobbered(root::_LLVMRef, lo::Int, hi::Int,
                         seq::Vector{LLVM.Instruction}, p1::Int, p2::Int,
                         names::Dict{_LLVMRef, Symbol}, ptr_cells::Bool, dl,
                         budget::Ref{Int})::Bool
    for k in (p1 + 1):(p2 - 1)
        budget[] -= 1
        budget[] <= 0 && return true                     # scan cap ⇒ fail closed
        f = _57hd_write_footprint(seq[k], dl)
        f === :unknown && return true
        for (r, l, h) in f
            _57hd_roots_disjoint(r, root) && continue
            r == root || return true                     # unproven-disjoint
            let s = _root_scale(LLVM.Value(root), names, ptr_cells)
                (s !== nothing && s[1] == 1) || return true   # byte tier only
            end
            (h <= lo || l >= hi) && continue
            return true                                  # genuine overlap
        end
    end
    return false
end

# Walk an `insertvalue` chain OUTERMOST-INWARD for the single-level index `j`.
# The outermost `insertvalue` is the LAST writer, so the first match is the
# correct one. Returns `nothing` when the chain does not yield an operand for
# `j` — because the aggregate came from a `load`, a `call` or a `phi`, or
# because some link is multi-index. Fails CLOSED. Pinned by gate (O).
function _57hd_insertvalue_field(agg::LLVM.Value, j::Int, depth::Int=0)
    depth > _57HD_DEPTH && return nothing
    agg isa LLVM.Instruction || return nothing
    LLVM.opcode(agg) == LLVM.API.LLVMInsertValue || return nothing
    LLVM.API.LLVMGetNumIndices(agg.ref) == 1 || return nothing
    idx = Int(unsafe_load(LLVM.API.LLVMGetIndices(agg.ref), 1))
    ops = LLVM.operands(agg)
    idx == j && return ops[2]
    return _57hd_insertvalue_field(ops[1], j, depth + 1)
end

# The canonical value ref that `v` PROVABLY equals, computed by a straight-line
# copy analysis confined to `blk`.
#
# INTRA-BLOCK ONLY, AND THIS IS THE POINT. A straight-line range within ONE
# basic block is the only range whose "no write happened in between" is a
# statement about EXECUTION rather than about LAYOUT: a "reaching store" in
# block A need not execute before a load in block B, and under a loop the store
# re-executes each iteration. A prototype that linearised all blocks and scanned
# by position in that list is UNSOUND IN GENERAL; it happened to be harmless on
# the corpus only because the admitted cluster lives entirely in `%top`.
#
# Generalising to a dominance-based version needs a dominator tree the extractor
# does not build, and buys NOTHING on the corpus — the `%L21`/`%L43` clusters it
# would be aimed at are already admitted by §4a. Tracked as Bennett-v7gv.
#
# ┌──────────── LOOP SAFETY — WHY NO BACK-EDGE VETO IS NEEDED ────────────────┐
# │ A reader who knows the block may sit inside a loop will reach for a       │
# │ back-edge check. DO NOT ADD ONE; it is unnecessary, and the reason is     │
# │ worth carrying because its absence otherwise looks like an oversight.     │
# │                                                                          │
# │ A basic block executes AS A STRAIGHT LINE ON EVERY ENTRY: control enters  │
# │ only at the top and leaves only at the terminator. So every fact this     │
# │ walker establishes — "the store at k wrote slot S", "nothing between k    │
# │ and pv wrote S" — is a statement about ONE ITERATION, and the load at pv  │
# │ reads what the store at k wrote IN THAT SAME ITERATION. A previous        │
# │ iteration's write is irrelevant precisely because the current iteration   │
# │ overwrote it at k before reaching pv.                                     │
# │                                                                          │
# │ (V2) additionally requires `%S` and `%T` to be in THIS block, so neither  │
# │ can be a value carried across a back edge: LLVM SSA admits a use of a     │
# │ definition from an earlier iteration only through a `phi`, and a `phi` is │
# │ not a pointer-result `load`, so `_57hd_canon` returns it unchanged and    │
# │ (V0) refuses it as a source outright. `%S` and `%T` therefore always      │
# │ denote values of the SAME iteration, and the identity proved between them │
# │ holds on every entry. Verified by hostile-review probes P1 / P1b and      │
# │ pinned as gates (T) / (T2) of `test/test_57hd_value_identity.jl`.         │
# └──────────────────────────────────────────────────────────────────────────┘
#
# MEMOISATION NOTE: a cached entry can only ever be CONSERVATIVE. The depth cap
# returns `v.ref` (the value itself), which is the fail-closed answer, so
# reusing a truncated result at a shallower depth can only cause a REJECT.
function _57hd_canon(v::LLVM.Value, blk::LLVM.BasicBlock,
                     seq::Vector{LLVM.Instruction},
                     order::Dict{_LLVMRef, Int},
                     names::Dict{_LLVMRef, Symbol},
                     suppressed::Set{_LLVMRef}, ptr_cells::Bool, dl,
                     memo::Dict{_LLVMRef, _LLVMRef},
                     budget::Ref{Int}, depth::Int=0)::_LLVMRef
    depth > _57HD_DEPTH && return v.ref
    budget[] -= 1
    budget[] <= 0 && return v.ref
    haskey(memo, v.ref) && return memo[v.ref]
    v isa LLVM.Instruction || return v.ref
    LLVM.parent(v).ref == blk.ref || return v.ref            # INTRA-BLOCK ONLY
    LLVM.opcode(v) == LLVM.API.LLVMLoad || return v.ref
    LLVM.value_type(v) isa LLVM.PointerType || return v.ref
    pv = get(order, v.ref, 0)
    pv == 0 && return v.ref

    (root0, off) = _p06b_slot_key(LLVM.operands(v)[1])
    root = _57hd_canon(LLVM.Value(root0), blk, seq, order, names, suppressed,
                       ptr_cells, dl, memo, budget, depth + 1)
    w = 8                                                    # a pointer is one cell
    res = v.ref

    # (a) STORE-FORWARD — the LAST store before `v` whose canonical slot COVERS
    # `[off, off+w)`. A partially-overlapping store nearer `v` is caught by the
    # clobber scan, so taking the last COVERING one is safe.
    for k in (pv - 1):-1:1
        s = seq[k]
        LLVM.opcode(s) == LLVM.API.LLVMStore || continue
        sops = LLVM.operands(s)
        (sroot0, soff) = _p06b_slot_key(sops[2])
        sroot = _57hd_canon(LLVM.Value(sroot0), blk, seq, order, names,
                            suppressed, ptr_cells, dl, memo, budget, depth + 1)
        sroot == root || continue
        sty = LLVM.value_type(sops[1])
        ssz = Int(LLVM.storage_size(dl, sty))
        (soff <= off && off + w <= soff + ssz) || continue
        # (V3) CLAUSE (iv) — the store must target a P06B-CERTIFIED CELL
        # POINTER. Without it the walk could "prove" a copy step through a
        # store the extraction never materialises as cells: §4a clause (i)'s
        # own disclosure ("does not provide sentinel-freedom for load-sourced
        # values") is that hole one hop up. Pinned by gate (N).
        (_p06b_cell_ptr_target_kind(LLVM.Value(sroot), names, ptr_cells,
                                    suppressed)[1] === :none) && break
        _57hd_clobbered(root, off, off + w, seq, k, pv, names, ptr_cells, dl,
                        budget) && break
        if sty isa LLVM.StructType
            nf = LLVM.API.LLVMCountStructElementTypes(sty.ref)
            for j in 0:(Int(nf) - 1)
                Int(LLVM.offsetof(dl, sty, j)) == off - soff || continue
                ft = LLVM.LLVMType(LLVM.API.LLVMStructGetTypeAtIndex(sty.ref, UInt32(j)))
                ft isa LLVM.PointerType || break
                fv = _57hd_insertvalue_field(sops[1], j)
                fv === nothing && break
                res = _57hd_canon(fv, blk, seq, order, names, suppressed,
                                  ptr_cells, dl, memo, budget, depth + 1)
                break
            end
        elseif off == soff && sty isa LLVM.PointerType
            res = _57hd_canon(sops[1], blk, seq, order, names, suppressed,
                              ptr_cells, dl, memo, budget, depth + 1)
        end
        break
    end

    # (b) SAME-SLOT RELOAD — the last earlier pointer `load` of the SAME
    # canonical slot with a clobber-free window. THIS IS THE STEP THE SCOUT
    # IDENTIFIED AS MISSING: `_p06b_slot_key` gives `(%"jl_global#93", 8)` and
    # `(%9, 8)` for the corpus's two `.data` loads — identical offsets, and the
    # roots differ ONLY because `%9` had not been canonicalised.
    if res == v.ref
        for k in (pv - 1):-1:1
            l = seq[k]
            LLVM.opcode(l) == LLVM.API.LLVMLoad || continue
            LLVM.value_type(l) isa LLVM.PointerType || continue
            (lroot0, loff) = _p06b_slot_key(LLVM.operands(l)[1])
            loff == off || continue
            lroot = _57hd_canon(LLVM.Value(lroot0), blk, seq, order, names,
                                suppressed, ptr_cells, dl, memo, budget, depth + 1)
            lroot == root || continue
            _57hd_clobbered(root, off, off + w, seq, k, pv, names, ptr_cells,
                            dl, budget) && break
            res = _57hd_canon(l, blk, seq, order, names, suppressed, ptr_cells,
                              dl, memo, budget, depth + 1)
            break
        end
    end

    # UNDEF / POISON ARE UNIQUED BY LLVM, so two INDEPENDENT chains that both
    # bottom out in `ptr undef` (or `ptr poison`) canonicalise to the SAME ref
    # and the equality test in (V2) passes for two values that are not equal —
    # they are not even values. Measured (hostile-review probe `probe4.jl` Q2):
    # two separate boxes, each with `insertvalue … ptr poison, 0`, gave
    # `pred = x=>true, y=>true`. Today the Bennett-bjdg arm rejects the fixture
    # downstream for an unrelated reason, i.e. THIS ARM'S SOUNDNESS SURFACE WAS
    # BEING COVERED BY ANOTHER ARM'S GUARD. Refuse here instead. Gate (D5).
    # NOTE the `!= 0`: `LLVMIsUndef` / `LLVMIsPoison` return an `LLVMBool`
    # (`Cint`), NOT a value ref. Comparing either against `C_NULL` is TRUE for
    # every input — measured, it reset every canonical result and rejected the
    # corpus. The `LLVMIsA*` family returns refs; the `LLVMIs*` predicates
    # return Cint. Do not "make them consistent".
    if res != v.ref &&
       (LLVM.API.LLVMIsUndef(res) != 0 || LLVM.API.LLVMIsPoison(res) != 0)
        res = v.ref
    end

    memo[v.ref] = res
    return res
end

# (V0) A certified, named, unsuppressed cell producer — §4a clause (i) verbatim.
#
# LOAD-BEARING FOR SOUNDNESS, NOT HYGIENE — do not "simplify it away" on the
# grounds that `x − x = 0` holds for any two cells. The REACHABLE hazard is the
# ASYMMETRIC pair: a PointerType `phi`/`select` carries the Bennett-cc0 M2b
# WIDTH-0 SENTINEL (its routing lives in `ptr_provenance` at LOWERING time
# rather than as a value), so coercing one emits an `:or` identity over a cell
# that was NEVER MATERIALISED, which ADR 0018 §E reads as 0. If the walk can
# forward the OTHER side's load to that same `phi`, `_57hd_canon` agrees while
# one cell holds `φ(p)` and the other holds 0: native computes `p − p = 0`, the
# VM computes `0 − φ(p) ≠ 0`. A SILENT MISCOMPILE, and this clause is the only
# thing that closes it. Pinned by gate (M).
function _57hd_certified(v, names::Dict{_LLVMRef, Symbol},
                         suppressed::Set{_LLVMRef})::Bool
    v isa LLVM.Instruction || return false
    _foz5_cert_src_kind(v) === :none && return false
    haskey(names, v.ref) || return false
    v.ref in suppressed && return false
    return true
end

"""
    _57hd_value_identity_cluster(pt, names, suppressed_refs, ptr_cells) -> Bool

ADR 0017 §4b. `true` iff every use of the `ptrtoint` `pt` is an i64 `sub` of two
`ptrtoint`s whose sources are certified cell producers in ONE basic block that
`_57hd_canon` reduces to the SAME canonical value — so the difference is
IDENTICALLY ZERO in the native program and in BennettVM, under ANY map from
addresses to cell values.

**The `sub`'s own uses are UNCONSTRAINED, deliberately.** That is the entire
content of the contract: an ORACLE-EXACT value needs no confinement, and may
escape into a live branch, an allocation size or a memmove length. A reader
arriving from `_foz5_confined_dead_bounds` will expect a (C2)/(C3) clause; its
absence here is a design decision, not an oversight.

PURE in `names` / `suppressed_refs` (read-only) and independent of
`dead_blocks`, so it may be called in BOTH the arm's entry and its admission
condition — entry-via-§4b therefore IMPLIES admission-via-§4b and the arm still
always returns or errors.
"""
function _57hd_value_identity_cluster(pt::LLVM.Instruction,
                                      names::Dict{_LLVMRef, Symbol},
                                      suppressed_refs::Set{_LLVMRef},
                                      ptr_cells::Bool)::Bool
    ptr_cells || return false
    src = LLVM.operands(pt)[1]
    _57hd_certified(src, names, suppressed_refs) || return false     # (V0)

    blk = LLVM.parent(src)
    seq = collect(LLVM.instructions(blk))
    order = Dict{_LLVMRef, Int}()
    for (k, i) in enumerate(seq)
        order[i.ref] = k
    end
    fn = LLVM.parent(blk)
    dl = LLVM.datalayout(LLVM.parent(fn))
    memo = Dict{_LLVMRef, _LLVMRef}()
    budget = Ref(_57HD_SCAN_CAP)

    cs = _57hd_canon(src, blk, seq, order, names, suppressed_refs, ptr_cells,
                     dl, memo, budget)

    saw = false
    for u in LLVM.uses(pt)
        saw = true
        usr = LLVM.user(u)
        # (V1) every use is a 2-operand i64 `sub` of two ptrtoints. The WIDTH
        # check is load-bearing for the same reason foz5's is (hostile review
        # D3): `sub` operands and result share a type, so an i32 cluster would
        # difference TRUNCATED cell values while satisfying the prose.
        (usr isa LLVM.Instruction && LLVM.opcode(usr) == LLVM.API.LLVMSub) || return false
        let st = LLVM.value_type(usr)
            (st isa LLVM.IntegerType && LLVM.width(st) == 64) || return false
        end
        ops = LLVM.operands(usr)
        length(ops) == 2 || return false
        sib = ops[1].ref == pt.ref ? ops[2] : ops[1]
        (sib isa LLVM.Instruction &&
         LLVM.opcode(sib) == LLVM.API.LLVMPtrToInt) || return false
        ssrc = LLVM.operands(sib)[1]
        _57hd_certified(ssrc, names, suppressed_refs) || return false   # (V0)
        LLVM.parent(ssrc).ref == blk.ref || return false                # (V2) one block
        _57hd_canon(ssrc, blk, seq, order, names, suppressed_refs, ptr_cells,
                    dl, memo, budget) == cs || return false             # (V2)
    end
    return saw
end

# ---- Bennett-jbko / CW-D: identity-use ptrtoint (pointer-equality guards) ----
#
#   %po = extractvalue { ptr, ptr } %ref, 0   ; a CERTIFIED 64-bit cell (6bu3)
#   %c  = ptrtoint ptr %po to i64             ; a no-op RE-TYPING under ptr_cells
#   %eq = icmp eq i64 %captured, %c           ; the ONLY admitted use shape
#
# ============================================================================
# WHY `icmp eq`/`ne` OF A COERCED IN-MODEL POINTER IS DETERMINISTIC/REVERSIBLE
# ============================================================================
#
# THE REPRESENTATION. Under `ptr_cells` a pointer is not an address in the
# host's sense; it is one Int64 **VM cell value** (ADR 0018 §A). BennettVM
# assigns those values with a DETERMINISTIC BUMP ALLOCATOR over its arena
# (`IntrinsicMalloc` / `gc_alloc_obj` / `jl_alloc_genericmemory_unchecked` all
# return `ARENA_BASE + s.arena_top`, `ARENA_BASE = Int64(1) << 40` frozen at
# compile time), and `arena_top` advances by a span determined solely by the
# program text and its inputs. No ASLR, no allocator nondeterminism. So for a
# fixed program and fixed inputs, the value in every pointer cell is a pure
# function of the execution trajectory, and copying a pointer (load/store,
# insertvalue/extractvalue, a call argument) copies the cell value verbatim.
# `ptrtoint` is therefore a PURE RETYPE, NOT A COMPUTATION: the cell already
# *is* the 64-bit integer, and there is nothing to convert.
#
# WHY THE VALUE MAY BE COMPARED BUT NOT COMPUTED WITH (oracle match). Write
# `φ : native address ↦ VM cell value` for the (injective) representation map.
# The extracted program must agree with native Julia on every observable, so
# the extractor may only admit operations `op` with `op(φ(x), φ(y)) = op(x, y)`
# — operations INVARIANT UNDER ANY INJECTIVE RELABELLING OF ADDRESSES.
#
#   * `eq` / `ne` ARE invariant: `φ(x) = φ(y) ⟺ x = y` for injective φ (a bump
#     cursor never hands the same base out twice within a trajectory). Pointer
#     equality is a LOCATION-IDENTITY predicate and identity survives
#     relabelling; equivalently, shifting the whole arena shifts both operands
#     equally and leaves `a == b` unchanged. This base-independence is the
#     direct analogue of Bennett-583s's base CANCELLATION, and it is what makes
#     the result a SOURCE-LEVEL fact rather than a LAYOUT fact.
#   * ORDERING (`ult`, `slt`, …) is NOT invariant: it compares address
#     MAGNITUDES, a property of the allocator's layout (and UB across
#     allocations in C). φ is injective but emphatically not monotone.
#   * ARITHMETIC is NOT invariant: it exposes ARENA_BASE to integer
#     computation, and BVM addressing is CELL-granular while native addressing
#     is byte-granular, so φ is not even affine — `φ(x) + 8` denotes nothing.
#   * ESCAPE into memory / a call / a `ret` / an `inttoptr` is NOT invariant:
#     once the coerced value leaves, the extractor can no longer prove its
#     consumers are φ-invariant, and a later `inttoptr` would dereference an
#     arena-relative integer as an address.
#
# RESIDUAL RISK — THE eq ARGUMENT IS PROVED OVER φ-IMAGES, THE CODE CHECKS
# LESS (hostile-review probe P1, 2026-08-06; tracked as Bennett-sku0).
# `φ(x) = φ(y) ⟺ x = y` presupposes that BOTH operands are φ-IMAGES, i.e. both
# are address-derived cell values. `_jbko_identity_use_violation` (~line 456)
# checks the icmp SIBLING only for SSA-NESS (`sib isa LLVM.Instruction ||
# sib isa LLVM.Argument`), NOT for CELL-NESS — strictly WEAKER than the
# invariance argument above. So a sibling that is a genuinely POINTER-UNRELATED
# integer (e.g. `%n = mul i64 %x, 7`) is ADMITTED, and the i1 it produces
# DIVERGES from native: native compares a malloc address against 7·x, the BVM
# compares `ARENA_BASE + k` against 7·x. The loud-halt mitigation in the
# FAILURE-MODE paragraph below is a property of the CORPUS SHAPE (these guards
# feed a throw block), not something this gate enforces. Reachability: no
# corpus witness found; judged LOW (the sibling would have to be an integer
# genuinely unrelated to any pointer) — which is why
# the arm landed as-is rather than blocked. Candidate levers in Bennett-sku0:
# (a) a sibling-KIND whitelist, noting that the real `_growend!` sibling
#     `%.unbox14` is a `load i64` of a CAPTURED cell, so a naive "sibling must
#     be ptr-typed" cell-ness test BREAKS the corpus witness; or
# (b) requiring the resulting i1 to reach a `br` through i1 algebra only
#     (proposal_A §7 R2).
#
# jbko ADDS ZERO EXPRESSIVE POWER over what the model already has. Bennett-8g7m
# / U80 (`instructions.jl:~2917`) ALREADY admits `icmp eq/ne` over
# POINTER-TYPED operands and already rejects ordering over them with exactly
# this argument. jbko only lets the SAME comparison be spelled through a
# coercion — which is what Julia emits when one side is a CAPTURED copy of the
# pointer that was stored as a plain `i64`. In the real corpus (`_growend!`
# `%L84`) Julia compares BOTH halves of one `MemoryRef`, and the `.mem` half
# already goes through `icmp eq ptr`; jbko admits the other half of the SAME
# comparison.
#
# REVERSIBILITY is inherited, not argued specially: the coercion lowers to a
# BVM `Define` (via `IRBinOp`) and the comparison to a `Define` carrying the
# predicate (via `IRICmp`). Both are non-destructive SSA creates, reversed by
# the standard L2/L3 machinery. The VM never learns an operand was a pointer.
#
# FAILURE MODE IF THE MODEL IS NEVERTHELESS WRONG: in Julia codegen these
# comparisons guard a throw block, which the Bennett-utzc pruner replaces with
# the `:__unreachable__` sink — so a wrong answer HALTS LOUDLY rather than
# silently producing a wrong value (Rule 1 property of the surrounding shape).
# ============================================================================

# (P2) Is `v` a pointer SSA value that `ptr_cells` has CERTIFIED as ONE 64-bit
# cell? Deliberately a POSITIVE WHITELIST of the two producer shapes that are
# PROVEN to stamp width 64 — NOT an "is a pointer" test:
#
#   * `extractvalue` of a StructType ptr field → `_struct_field_widths` stamps
#     64 ("a pointer is one Int64 VM cell, ADR 0018 §A"), and
#   * `load` with a PointerType result under `ptr_cells` → `IRLoad(…, 64)`
#     (the Bennett-ares arm, "ptr→cell width 64").
#
# CAVEAT ON THE `:load` ENTRY (a8nw review D4): `IRLoad(…, 64)` is NOT the only
# disposition of a pointer-result `load`. The bennettvm-416r.13 / CW-D3 Lever 2
# SINGLETON-DATA alias arm (~line 4202) runs FIRST for a
# `load ptr, ptr @"jl_global#N"`: it emits NO IRInst at all and instead ALIASES
# the load-result SSA name to the STABLE global symbol. Such a load is
# nevertheless admitted by this whitelist (opcode `Load`, PointerType result,
# addrspace 0), and the coercion's `_operand` then resolves to the `.globals`
# key that the VM binds via its prepended `GLOBAL_BASE` `Define` — still a
# 64-bit cell value, so the admission is BENIGN today. It is a second path, not
# a second contract: anyone reworking either arm must re-check this overlap.
#
# A pointer-typed `phi` / `select` carries the Bennett-cc0 M2b WIDTH-0
# SENTINEL: its routing is recorded in `ptr_provenance` at LOWERING time rather
# than as a value. Coercing one would emit an `:or` identity reading a cell
# that was NEVER MATERIALISED — a SILENT miscompile, not a loud one. Everything
# outside the whitelist (including cases that are probably sound, e.g. a
# `julia.gc_alloc_obj` call result) is REJECTED: Rule 1 prefers a conservative
# loud reject to an unverified admission. Widening this is a one-line change
# PLUS a fixture. Depth-0 by design — no chain walk, no recursion.
# Returns `:extractvalue`, `:load`, or `:none`.
function _jbko_cell_ptr_src_kind(v)::Symbol
    v isa LLVM.Instruction || return :none
    ty = LLVM.value_type(v)
    ty isa LLVM.PointerType || return :none
    LLVM.addrspace(ty) == 0 || return :none          # addrspace-0 only (cf. 7wsz)
    opc = LLVM.opcode(v)
    if opc == LLVM.API.LLVMExtractValue
        return LLVM.value_type(LLVM.operands(v)[1]) isa LLVM.StructType ?
               :extractvalue : :none
    elseif opc == LLVM.API.LLVMLoad
        return :load
    end
    return :none
end

# Human-readable description of a ptrtoint source, for the (P2) fail-loud.
#
# DEAD BRANCHES, DELIBERATELY KEPT (a8nw review D2). The `LLVM.Argument` arm and
# the non-instruction fallback below are UNREACHABLE as the code stands: the arm
# entry (~line 3331) requires `src isa LLVM.Instruction` before this is ever
# called, so a `ptrtoint` of a ptr ARGUMENT never reaches the (P2) fail-loud —
# it falls through to the GENERIC Bennett-iwo9 "not a recognised type-tag"
# reject instead (a8nw probe P14). Do not delete them: a ptr argument IS stamped
# width 64 (`module_walk.jl:306`, "one VM address cell"), so admitting it as a
# certified source is a live widening tracked in Bennett-vckk, which makes these
# branches reachable the same edit that adds `|| src isa LLVM.Argument` to the
# entry condition.
function _jbko_src_kind_name(v)::String
    v isa LLVM.Argument && return "a function argument"
    v isa LLVM.Instruction || return "a non-instruction value (global/alias/constexpr)"
    opc = LLVM.opcode(v)
    if opc == LLVM.API.LLVMExtractValue
        return "an `extractvalue` of a NON-struct aggregate"
    end
    return "a `$(_llvm_opcode_name(opc))`"
end

# (P3)+(P4) The dual of `_verify_memdata_bounds_cluster`: that gate proves a
# coerced address never escapes a base-CANCELLING subtraction, this one proves
# it never escapes an EQUALITY test. Both say "the coerced integer is used only
# in a way whose result is independent of ARENA_BASE" — the sole soundness
# boundary.
#
# EVERY use of `pt` must be an `icmp` with predicate eq/ne whose SIBLING
# operand is an in-model 64-bit value (an SSA instruction or a function
# argument) or the ZERO cell (null — Bennett-beaw). A NON-ZERO integer literal
# is a test against a hard-coded host address, which is layout-dependent by
# construction and has no portable meaning — rejected. A ptrtoint with NO uses
# is rejected too: a use-less coercion is evidence the walker's picture is
# incomplete, and surprises are loud (Rule 1 / the 583s conservatism).
#
# Returns `nothing` when every use is admissible, else a SHORT STRING naming
# the offending use (so the fail-loud says which one).
function _jbko_identity_use_violation(pt::LLVM.Instruction)::Union{Nothing,String}
    saw = false
    for u in LLVM.uses(pt)
        saw = true
        usr = LLVM.user(u)
        usr isa LLVM.Instruction || return "a non-instruction user"
        uopc = LLVM.opcode(usr)
        uopc == LLVM.API.LLVMICmp ||
            return "a use that is a `$(_llvm_opcode_name(uopc))`, not an icmp"
        pred = LLVM.predicate(usr)
        pred in (LLVM.API.LLVMIntEQ, LLVM.API.LLVMIntNE) ||
            return "an ORDERING icmp (predicate :$(_pred_to_sym(pred)))"
        ops = LLVM.operands(usr)
        length(ops) == 2 || return "an icmp with $(length(ops)) operands"
        sib = ops[1].ref == pt.ref ? ops[2] : ops[1]
        if sib isa LLVM.ConstantInt
            _const_int_as_int(sib) == 0 ||
                return "an icmp against the NON-ZERO integer literal " *
                       "$(_const_int_as_int(sib))"
        elseif !(sib isa LLVM.Instruction || sib isa LLVM.Argument)
            return "an icmp whose other operand is not an in-model SSA value"
        end
    end
    return saw ? nothing : "NO uses at all"
end

"""
    _gc_loaded_dst_elem_ref(gep_val) -> Union{Nothing, Tuple{_LLVMRef,_LLVMRef,Int}}

Bennett-qmv7 (2026-06): the HEAP-Memory analogue of `_gc_alloc_root_ref`, but
for the RUNTIME-INDEXED element store into a Julia `Memory`/`GenericMemory`
cell (the Dict keys/vals backing). Recognises a `setindex!`-style dst pointer

    %d    = call ptr @julia.gc_loaded(ptr %mem, ptr %data)   ; laundered data ptr
    %bo   = mul i64 %off, STRIDE                             ; byte offset = elem_idx * stride
    %addr = getelementptr inbounds i8, ptr %d, i64 %bo       ; single-index i8 GEP

and returns `(gc_loaded_call_ref, raw_element_index_ref, STRIDE)` — where
`raw_element_index_ref` is the PRE-`mul` `%off` (the 0-based ELEMENT index)
and `STRIDE` is the constant byte stride. Returns `nothing` for any other
shape.

  *** eln6 byte/cell contract (Bennett-eln6) — THE LOAD-BEARING REASON ***
The dst GEP is ALWAYS an `i8` GEP whose index is the BYTE offset `%off*STRIDE`
(Julia byte-GEPs into the Memory data region; the i8 source type is NOT the
element width). BVM's `IRVarGEP` lowering is CELL-addressed (stride 1, one
Int64 per cell) and consumes the index operand AS the element index. So
feeding the byte offset `%bo` directly (as the already-lowered
`IRVarGEP(:addr,:d,:bo,8)` would) addresses cell `off*STRIDE` — correct only
for STRIDE==1 (i8 coincidence), an `8×` misaddress for an i64-vals Memory.
This helper splits the `mul` and returns the RAW element index `%off` so the
caller emits a FRESH `IRVarGEP(dst, gc_loaded_base, off, value_ew)` — cell
`off`, correct for EVERY element width. This is the SAME `mul %off, STRIDE`
→ keep-`%off`, drop-`%bo` split the proven `mem=:vm` recogniser performs in
`vector_vm_walk.jl` (the D6/b5x stride pattern), applied at the memcpy-dst
site. NEVER feed the byte offset; NEVER use the i8 GEP type as the width.

Consulted ONLY under `ptr_cells=true` (see `_handle_memcpy_arm`); on the
circuit / `mem=:heap` model a gc_loaded heap cell has no semantics, so the
caller stays at the byte-identical fail-loud.
"""
function _gc_loaded_dst_elem_ref(gep_val::LLVM.Value
                                )::Union{Nothing, Tuple{_LLVMRef, _LLVMRef, Int}}
    gep_val.ref == C_NULL && return nothing
    (gep_val isa LLVM.Instruction &&
     LLVM.opcode(gep_val) == LLVM.API.LLVMGetElementPtr) || return nothing
    gep_ops = LLVM.operands(gep_val)
    # Single-index GEP only: base + exactly one index operand.
    length(gep_ops) == 2 || return nothing
    base = gep_ops[1]
    idx  = gep_ops[2]
    # Base must be a `julia.gc_loaded` call (callee = LAST operand, file-wide
    # convention).
    (base isa LLVM.Instruction &&
     LLVM.opcode(base) == LLVM.API.LLVMCall) || return nothing
    base_ops = LLVM.operands(base)
    nbo = length(base_ops)
    nbo >= 1 || return nothing
    callee_name = try
        LLVM.name(base_ops[nbo])
    catch e
        e isa InterruptException && rethrow()
        return nothing
    end
    callee_name == "julia.gc_loaded" || return nothing
    # Index must be `mul %off, STRIDE` with STRIDE a positive ConstantInt; the
    # surviving %off is the raw element index (eln6-safe — never the byte off).
    (idx isa LLVM.Instruction &&
     LLVM.opcode(idx) == LLVM.API.LLVMMul) || return nothing
    mul_ops = LLVM.operands(idx)
    length(mul_ops) >= 2 || return nothing
    off    = mul_ops[1]
    stride = mul_ops[2]
    stride isa LLVM.ConstantInt || return nothing
    stride_val = _const_int_as_int(stride)
    stride_val >= 1 || return nothing
    return (base.ref, off.ref, stride_val)
end

"""
    _alloca_elem_width_bits(alloca_ref) -> Int

Returns the alloca's element width in bits, or 0 if the allocated type
is not a Bennett-supported integer-or-integer-array shape (struct, ptr,
nested array, non-integer inner).

Supported shapes:
  - `iN` IntegerType — returns N (Bennett-munq accepted `i8`; ixiz
    extended to arbitrary `iN`, but `iN` already worked via the
    IntegerType branch above).
  - `[K x iN]` ArrayType wrapping an IntegerType — returns N. Bennett-
    munq accepted only `[K x i8]`; Bennett-ixiz (2026-05-16) lifted the
    `LLVM.width(inner) == 8` gate to accept arbitrary integer inner
    widths (`[K x i16]`, `[K x i32]`, `[K x i64]`, ...).

Nested ArrayType (`[K x [M x i8]]`) still returns 0 — the
`inner isa LLVM.IntegerType || return 0` guard rejects the nested case
because the inner of a nested ArrayType is itself ArrayType, not
IntegerType. Future-deferred to a follow-up bead (Bennett-8bys
catch-all).
"""
function _alloca_elem_width_bits(alloca_ref::_LLVMRef)::Int
    elem_ty = LLVM.LLVMType(LLVM.API.LLVMGetAllocatedType(alloca_ref))
    if elem_ty isa LLVM.IntegerType
        return LLVM.width(elem_ty)
    end
    if elem_ty isa LLVM.ArrayType
        inner = LLVM.eltype(elem_ty)
        inner isa LLVM.IntegerType || return 0
        return LLVM.width(inner)
    end
    return 0
end

"""
    _handle_memcpy_arm(cname, inst, names, counter, ops, globals) -> Vector{IRInst}

Bennett-37mt Phase 1 + Bennett-doih (2026-05-16): const-size memcpy.
Two arms post-doih:

  - **Non-global arm (37mt + ixiz):** distinct `alloca iM`-backed src/dst,
    lowered as K element-granular IRPtrOffset+IRLoad+IRStore chunks where
    K = N / ew_bytes and width = dst_ew (8/16/32/64 — same on both sides).
  - **Global-src arm (doih):** src is a constant global from the
    `parsed.globals` dict, dst is a fresh alloca. Lowered as K element-
    granular IRPtrOffset+IRStore(iconst) chunks pulling the value from
    the global's data words. See `_handle_memcpy_global_src` for the
    G1-G9 sub-cascade. DST-as-global is still rejected (writable target
    makes no sense for a constant).

Out-of-scope shapes fail loud with a precise message naming the
appropriate downstream bead (`Bennett-8bys` for the catch-all,
`Bennett-doih-struct` / `Bennett-doih-wide` / `Bennett-doih-vargep` for
the doih follow-up cases).

Predicates checked, in order, so the earliest mismatch produces the
most actionable error:

  1. addrspace 0 only (cname must be `llvm.memcpy.p0.p0.*`)
  2. `isvolatile == false`
  3. N is a `ConstantInt` (≥ 0)
  4. N == 0 → return `IRInst[]` (legal no-op)
  5a. dst operand is NOT a global variable (still rejected)
  5b. if src operand IS a global variable → dispatch to
      `_handle_memcpy_global_src` (doih arm)
  6. both operands trace to an alloca (direct or via const-offset GEP) —
     OR, under `ptr_cells` (Bennett-sy29), to a `julia.gc_alloc_obj` ARENA
     call via `_gc_alloc_root_ref`, on EITHER side
  6c. (Bennett-sy29) an ARENA operand's byte offset from its root is a
      compile-time constant and a multiple of 8 (cell-aligned)
  6d. (Bennett-sy29, hostile-review fix D2) EACH operand's range stays
      INSIDE its own object: `0 <= off` and `off + N <= capacity(root)`,
      whenever `_root_scale` can prove a capacity. This is the PRECONDITION
      that makes predicate 7's disjointness argument true — without it,
      distinct roots do NOT imply disjoint ranges (BennettVM bump-allocates,
      so `%a + 24` can BE `%b + 8`), and the miscompile is executed, not
      hypothetical. Also closes a pre-existing alloca↔alloca bounds hole.
  7. distinct ROOTS (rejects `memcpy(p, p, N)` self-copy). Generalised by
     Bennett-sy29 from "same alloca" to "same root, whichever kind" — route
     R1 never emits an `IntrinsicMemcpy`, so this REPLACES BennettVM's
     runtime overlap check rather than duplicating it. Sound only in
     combination with 6d
  8. both operands' element width is a known non-zero integer width; an
     ARENA side is fixed at 64 (BennettVM ADR 0018 §A)

The `globals` arg is the ParsedIR globals dict threaded down from
`_module_to_parsed_ir_on_func`; empty for non-doih invocations.
"""
function _handle_memcpy_arm(cname::AbstractString, inst::LLVM.Instruction,
                            names::Dict{_LLVMRef, Symbol}, counter::Ref{Int}, ops,
                            globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}=
                                Dict{Symbol, Tuple{Vector{UInt64}, Int}}();
                            synth_ptr_provenance::Set{Tuple{Symbol, Int, Int}}=
                                Set{Tuple{Symbol, Int, Int}}(),
                            synth_ptr_allocas::Set{_LLVMRef}=Set{_LLVMRef}(),
                            ptr_cells::Bool=false)
    # Predicate 1: addrspace 0 on both pointers (encoded in the intrinsic name).
    startswith(cname, "llvm.memcpy.p0.p0.") || _ir_error(inst,
        "$(cname): memcpy with non-default pointer address space is not " *
        "supported. Bennett.jl's wire model is single-address-space; " *
        "cross-space copies need explicit lowering. Tracked in " *
        "Bennett-8bys. (Bennett-37mt Phase 1 — addrspace 0 only)")

    n_ops = length(ops)
    n_ops >= 5 || _ir_error(inst,
        "$(cname): malformed memcpy call (expected 4 args + callee, got " *
        "$(n_ops - 1) args). (Bennett-37mt Phase 1)")

    dst_v = ops[1]
    src_v = ops[2]
    n_v   = ops[3]
    vol_v = ops[4]

    # Predicate 2: isvolatile must be a ConstantInt with value 0.
    vol_v isa LLVM.ConstantInt || _ir_error(inst,
        "$(cname): isvolatile arg is not an i1 immarg constant " *
        "(value=$(string(vol_v))). LangRef requires an immarg here; " *
        "malformed IR. (Bennett-37mt Phase 1)")
    _const_int_as_int(vol_v) == 0 || _ir_error(inst,
        "$(cname): volatile memcpy is not supported. Bennett.jl's " *
        "reversible model has no observable side-effect ordering for " *
        "memory; volatile semantics cannot be honoured. Recompile " *
        "without the volatile attribute, or wait on Bennett-8bys " *
        "(catch-all). (Bennett-37mt Phase 1)")

    # Predicate 3: byte count must be a ConstantInt.
    n_v isa LLVM.ConstantInt || _ir_error(inst,
        "$(cname): memcpy with non-constant byte count is not supported. " *
        "Variable-size memcpy requires runtime-bounded loop unrolling. " *
        "Tracked in Bennett-8bys (Phase 3: variable-size). " *
        "(Bennett-37mt Phase 1 — const-N only)")
    N = _const_int_as_int(n_v)
    N >= 0 || _ir_error(inst,
        "$(cname): negative byte count $N (corrupt IR; LLVM treats the " *
        "size argument as unsigned i64 but the C API returns Int64). " *
        "(Bennett-37mt Phase 1)")

    # Predicate 4: N == 0 is a legal no-op.
    N == 0 && return IRInst[]

    # Predicate 5a (Bennett-doih, 2026-05-16): DST cannot be a global —
    # the global is read-only constant data; writing to it would mutate
    # text-section memory, which Bennett's reversible model has no
    # semantics for. Remains a hard reject; tracked in Bennett-8bys for
    # any future fancy dst-global semantics (e.g. shadow-copy buffer).
    if LLVM.API.LLVMIsAGlobalVariable(dst_v.ref) != C_NULL
        _ir_error(inst,
            "$(cname): memcpy with a global-variable dst pointer is not " *
            "supported — global data is read-only constant memory and " *
            "Bennett's reversible model has no semantics for mutating it. " *
            "Tracked in Bennett-8bys (catch-all, sub-case: \"Global- " *
            "pointer dst memcpy\"). " *
            "(Bennett-doih — global-src memcpy supported; global-dst rejected)")
    end

    # Predicate 5b (Bennett-doih): SRC may be a global — dispatch to
    # the new global-src arm. Two ways src can reach the global:
    #   (i) direct global reference (`memcpy(_, @g, _, _)`)
    #   (ii) const-GEP wrapping a global (`memcpy(_, getelementptr i8,
    #        ptr @g, i32 OFF, _, _)`) — common when the source pointer
    #        is offset into a larger constant.
    # `_global_root_and_offset` handles both forms; if it returns
    # non-nothing we route to the global-src arm. Variable-GEP src
    # (runtime index into a global) is rejected inside that helper
    # with a precise Bennett-doih-vargep breadcrumb.
    if _src_reaches_global(src_v)
        return _handle_memcpy_global_src(cname, inst, names, counter, ops, globals;
                                         synth_ptr_provenance=synth_ptr_provenance,
                                         synth_ptr_allocas=synth_ptr_allocas,
                                         ptr_cells=ptr_cells)
    end

    # Predicate 6: both pointers must trace back to an alloca.
    dst_root = _alloca_root_ref(dst_v)
    src_root = _alloca_root_ref(src_v)

    # Bennett-qmv7 (2026-06): under the closed-world `ptr_cells` gate, a memcpy
    # whose DST is a runtime-indexed element store into a `julia.gc_loaded`
    # heap-Memory cell (the dual of vbv9's const-offset gc_alloc ARENA dst) is a
    # valid VM heap pointer (the Dict keys/vals backing). The src is the
    # alloca-backed value box (the sret `[2 x i64]` field on the fdict root).
    # Route to `_handle_memcpy_gc_loaded`, which recovers the RAW element index
    # (splitting the `mul %off, STRIDE` — eln6-safe) and emits a fresh
    # IRVarGEP+IRLoad+IRStore at the VALUE element width. The circuit path
    # (`ptr_cells=false`) skips this branch entirely → byte-identical fail-loud
    # at the unchanged Predicate-6 reject below.
    if ptr_cells && dst_root === nothing
        heap_dst = _gc_loaded_dst_elem_ref(dst_v)
        if heap_dst !== nothing
            return _handle_memcpy_gc_loaded(cname, inst, names, counter, ops,
                                            heap_dst, src_root)
        end
    end

    # ---- Bennett-sy29 (2026-08-07, xkl frontier wall 9) ----------------------
    # An `julia.gc_alloc_obj` ARENA root on EITHER SIDE of the memcpy, under the
    # closed-world `ptr_cells` gate. This is the MIRROR of the vbv9 arena-dst arm
    # (which lives on the global-src path), carrying the Bennett-4y0d
    # address/value stamp split applied PER SIDE. The corpus that forces it is
    # the push! ROOT body:
    #
    #     %sz  = alloca i64                                   ; WORD tier, scale 8
    #     %obj = call ptr @julia.gc_alloc_obj(_, i64 24, _)   ; BYTE tier, scale 1
    #     %p   = getelementptr inbounds i8, ptr %obj, i32 16
    #     call void @llvm.memcpy.p0.p0.i64(ptr %sz, ptr %p, i64 8, i1 false)
    #
    # — reading the boxed `Array`'s `size` field into a stack temp (3 sites), and
    # its transposed mirror at `%L18` writing a stack temp back into arena +16.
    #
    # *** SOUNDNESS: THE CELL-MAP ARGUMENT FOR A MIXED-TIER PAIRING ***
    #
    # `IRPtrOffset(d, b, off, ew)` lowers to `Define(d, b, :add, off ÷ (ew÷8))`
    # (`BennettVM/src/ir/ingest_body.jl:534`), so `elem_width` IS the addressed
    # object's bytes-per-cell scale — nothing else. The two sides of this memcpy
    # have DIFFERENT scales, and that is fine, because they are two INDEPENDENT
    # address computations off two independent roots:
    #
    #   | side  | root                        | scale | stamp | cell of elem k |
    #   |-------|-----------------------------|-------|-------|----------------|
    #   | arena | `julia.gc_alloc_obj` (byte) | 1     | 8     | `base + 8k`    |
    #   | alloca| `alloca i64`        (word)  | 8     | 64    | `base + k`     |
    #
    # The quantity the two sides SHARE is neither the offset nor the stamp: it is
    # the 64-bit VALUE, and a 64-bit value occupies exactly ONE cell in BOTH
    # tiers (byte tier: the cell at the value's base byte address, `+1…+7` never
    # named — the bennettvm-416r.13 / 9n3y / vbv9 convention; word tier: cell k).
    # So `K = N/8` and element k is the single-cell move `src_cell → dst_cell`
    # with each cell computed under its OWN root's map. The same argument
    # transposes for the mirror direction, and degenerates to today's shipped
    # alloca↔alloca path when both scales are 8.
    #
    # *** SOUNDNESS: THE OVERLAP GUARD REPLACES A CHECK, IT DOES NOT ADD ONE ***
    #
    # `llvm.memcpy`'s LangRef contract forbids src/dst overlap. Route R1 (this
    # per-cell decomposition) BYPASSES BennettVM's runtime overlap check
    # entirely: that check lives in `forward(::IntrinsicMemcpy)`
    # (`BennettVM/src/ir/intrinsics_bulk.jl:117-121`) and R1 never emits an
    # `IntrinsicMemcpy` — it emits load/store pairs. R1's ascending per-element
    # load-then-store genuinely miscopies an overlapping range. So the
    # extraction-time distinctness guard (Predicate 7, generalised below from
    # "same alloca ref" to "same ROOT ref, whichever kind") is LOAD-BEARING and
    # is REPLACING the VM's check, not duplicating it.
    #
    # THE ASYMMETRY WITH Bennett-vau9 (variable-size memmove), restated so it is
    # not mistaken for an inconsistency: memmove is ALLOWED to overlap and routes
    # to `IRCall(:memmove)` precisely because BVM's `_copy_range!` snapshots the
    # whole src range before writing (`intrinsics_bulk.jl:100-113`) — overlap-safe
    # by construction. memmove DELEGATES overlap safety to the VM; sy29 must
    # PROVE disjointness at extraction, because nothing downstream will.
    #
    # *** THE DISJOINTNESS CLAIM, STATED CORRECTLY (hostile-review fix D2) ***
    #
    # An earlier revision of this comment claimed flatly that "two distinct
    # static allocation sites yield disjoint ranges, because both BVM allocators
    # are monotone bumps". THAT IS A FALSE THEOREM, and the counterexample is
    # EXECUTED (reviewer probe `p2_overlap_vm`): the arena bump makes a 16-byte
    # `gc_alloc_obj` %a immediately adjacent to %b, so `%a + 24` IS `%b + 8`, and
    # a memcpy with dst rooted at %a and src rooted at %b then has distinct roots
    # and genuinely overlapping ranges — miscopied by this arm as `s = 222`
    # against an oracle of `333`. Monotone bumps make distinct ALLOCATIONS
    # disjoint; they say nothing about distinct ROOTS once a GEP walks out of its
    # own object.
    #
    # The correct statement has a precondition, and Predicate 6d below ENFORCES
    # that precondition rather than assuming it:
    #
    #   Two distinct allocation roots yield disjoint ranges **provided each
    #   range stays inside its own object** — i.e. `0 <= off` and
    #   `off + N <= capacity(root)` on BOTH operands.
    #
    # With 6d in force the argument is sound: both BVM allocators are monotone
    # bumps and distinct allocas are distinct frame slots, so two IN-OBJECT
    # ranges off distinct roots cannot intersect. For the corpus it is
    # additionally STRUCTURAL — the src root is a `julia.gc_alloc_obj` call
    # served out of the ARENA region (`arena_top`) and the dst root is an
    # `alloca` served out of the STACK region (`stack_top`), different regions
    # entirely.
    #
    # The guard is still deliberately NOT weakened to a general byte-range
    # disjointness test across DIFFERENT roots: that would be a new alias
    # analysis Bennett does not have, and CLAUDE.md Rule 1 prefers the loud
    # refusal. 6d is not that analysis — it is a per-operand bound against a
    # capacity `_root_scale` already reports.
    #
    # *** REVERSIBILITY, for the ARENA-DST direction (the mirror) ***
    #
    # An arena-dst memcpy DESTRUCTIVELY OVERWRITES a live cell. vbv9's STEP-0c
    # freshness argument (gc_alloc zero-inits, field-inits hit distinct offsets)
    # does NOT cover it — do not claim it. The correct citation is Bennett-u2kk's
    # REVERSIBILITY JUSTIFICATION: the write is reversed by BennettVM's
    # Bennett-1973 history tape `(cell, pre-image)`, not by a freshness
    # precondition. Freshness is a CIRCUIT-MODEL artifact (the circuit path has
    # no tape), which is exactly why this whole branch is `ptr_cells`-gated and
    # the circuit path keeps failing loud at the UNCHANGED Predicate-6 walls
    # below.
    #
    # *** THE CIRCUIT PATH IS BYTE-IDENTICAL, STRUCTURALLY ***
    #
    # Both arena roots are consulted only under `ptr_cells`, so with
    # `ptr_cells=false` `arena_dst`/`arena_src` are `nothing`, every predicate
    # below reduces to its pre-sy29 form, and the two Predicate-6 messages are
    # unchanged character-for-character (the vbv9 / u2kk / qmv7 gating pattern,
    # pinned by `test_37mt` and `test_lqif`).
    arena_dst = (ptr_cells && dst_root === nothing) ?
        _gc_alloc_root_ref(dst_v) : nothing
    arena_src = (ptr_cells && src_root === nothing) ?
        _gc_alloc_root_ref(src_v) : nothing

    (dst_root === nothing && arena_dst === nothing) && _ir_error(inst,
        "$(cname): memcpy dst operand is not alloca-backed (or " *
        "alloca-backed via a const-offset GEP). Bennett's pointer- " *
        "provenance model only covers alloca and GEP-of-alloca; pointer " *
        "phi/select/parameter sources fan out to multiple origins which " *
        "Bennett-37mt does not yet handle. Tracked in Bennett-8bys. " *
        "(Bennett-37mt Phase 1)")
    (src_root === nothing && arena_src === nothing) && _ir_error(inst,
        "$(cname): memcpy src operand is not alloca-backed (or " *
        "alloca-backed via a const-offset GEP). Same restriction as " *
        "the dst case; tracked in Bennett-8bys. (Bennett-37mt Phase 1)")

    # The EFFECTIVE root of each side — an alloca ref or an arena-call ref. Used
    # by Predicate 7 (distinctness) and by the Bennett-land carry-through.
    eff_dst_root = dst_root === nothing ? arena_dst : dst_root
    eff_src_root = src_root === nothing ? arena_src : src_root

    # Predicate 6c (Bennett-sy29): an ARENA operand's byte offset from its root
    # must be a compile-time constant AND a whole multiple of 8. See
    # `_gc_alloc_root_offset`'s docstring for why (SC) cannot supply this guard.
    # KNOWN RESIDUAL, filed rather than inherited silently: the vbv9 arena-DST
    # branch on the global-src path (`_handle_memcpy_global_src` G3/G7) checks
    # the GLOBAL's offset but not the arena dst's own — the same corner, one arm
    # over. Tracked on Bennett-8bys.
    for (side, side_v, side_root) in (("dst", dst_v, arena_dst),
                                      ("src", src_v, arena_src))
        side_root === nothing && continue
        aoff = _gc_alloc_root_offset(side_v)
        aoff === nothing && _ir_error(inst,
            "$(cname): memcpy $(side) operand is rooted at a " *
            "`julia.gc_alloc_obj` ARENA allocation, but its byte offset from " *
            "that root could not be resolved to a compile-time constant. One " *
            "of: a RUNTIME GEP index; a STRUCT-typed GEP source element type " *
            "(constant, but this walker flattens only integer and array " *
            "sources); a non-zero first index into an `ArrayType` source; or " *
            "a GEP chain deeper than $(_BVMD_ROOT_DEPTH). Cell alignment is " *
            "therefore unprovable, and an unaligned arena chunk has no " *
            "faithful single-cell gather. Tracked in Bennett-8bys. " *
            "(Bennett-sy29, predicate `_gc_alloc_root_offset`)")
        aoff >= 0 || _ir_error(inst,
            "$(cname): memcpy $(side) operand sits at NEGATIVE byte offset " *
            "$(aoff) of its `julia.gc_alloc_obj` ARENA root — the GEP chain " *
            "points BEFORE the start of the allocation, which addresses no " *
            "cell of this object at all (BennettVM reserves cells " *
            "`[root, root+nbytes)`). Note this is a SEPARATE clause from " *
            "cell-alignment, and the distinction is not academic: $(aoff) " *
            (rem(aoff, 8) == 0 ?
             "IS a multiple of 8, so the alignment clause would have passed " *
             "it — the sign is what refuses it" :
             "is not a multiple of 8 either, but the SIGN is reported here " *
             "because it is the stronger objection") *
            ". Tracked in Bennett-8bys. " *
            "(Bennett-sy29, predicate `_gc_alloc_root_offset`)")
        rem(aoff, 8) == 0 || _ir_error(inst,
            "$(cname): memcpy $(side) operand sits at byte offset $(aoff) of " *
            "its `julia.gc_alloc_obj` ARENA root, which is not cell-aligned " *
            "(a multiple of 8). BennettVM's BYTE tier names a 64-bit value by " *
            "its BASE byte address and never names bytes +1…+7, so a sub-cell " *
            "chunk straddles two named cells and no `IRLoad`/`IRStore` pair " *
            "can express it. NOTE this is NOT a scale-coherence violation — a " *
            "byte GEP off a byte-tier root is coherent by construction, which " *
            "is precisely why this predicate exists separately from " *
            "`_check_scale_coherence!`. Tracked in Bennett-8bys. " *
            "(Bennett-sy29, predicate `_gc_alloc_root_offset`)")
    end

    # ---- Predicate 6d (Bennett-sy29 hostile-review fix D2): IN-OBJECT RANGE ---
    #
    # *** THIS PREDICATE IS WHAT MAKES THE DISJOINTNESS ARGUMENT TRUE. ***
    #
    # The overlap argument above ("two distinct static allocation sites yield
    # disjoint ranges, because both allocators are monotone bumps") is a FALSE
    # THEOREM without this check, and the counterexample is EXECUTED, not
    # hypothetical. BennettVM's arena is a monotone bump, so a 16-byte
    # `gc_alloc_obj` %a is immediately followed by %b — hence `%a + 24` IS
    # `%b + 8`. A memcpy with dst rooted at %a (address %a+24) and src rooted at
    # %b has DISTINCT ROOTS and GENUINELY OVERLAPPING RANGES, and route R1's
    # ascending load-then-store then miscopies it: measured `s = 222` against an
    # oracle of `333` on the reviewer's `p2_overlap_vm` probe. A second symptom
    # from the same hole: an arena src range running past its own reservation
    # silently READS THE NEXT OBJECT (`leak = 999`).
    #
    # Distinct roots imply disjoint ranges ONLY FOR RANGES THAT STAY INSIDE
    # THEIR OWN OBJECT. So require exactly that, on BOTH operands:
    #
    #     0 <= root_offset  and  root_offset + N <= capacity_bytes
    #
    # The predicate ships one arm over already — `_handle_memcpy_global_src`'s
    # G8 bounds-checks the global side against `length(gdata) * ew_bytes` — and
    # both halves it needs are in hand: `_root_scale` ALREADY returns capacity
    # (`gc_alloc` → `(1, nbytes)`, `alloca` → `(ew÷8, n)`, `malloc` → `(8, nb÷8)`)
    # and `_root_byte_offset` supplies the offset from that same root.
    #
    # THIS ALSO CLOSES A PRE-EXISTING alloca↔alloca HOLE. Before sy29 the
    # alloca↔alloca path had no bounds check either — `memcpy(%slot, gep i8
    # %other, 24, 16)` off an `alloca i64, i32 2` walked off the end just as
    # happily. The generalised predicate now owns both paths, so both are fixed;
    # that is a strict improvement, not scope creep.
    #
    # THE BOUND IS `<=`, NOT `<`, AND THE CORPUS IS EXACTLY FLUSH ON BOTH SIDES:
    # src `gep i8 %"new::Array", 16` off `gc_alloc_obj(_, 24, _)` gives
    # `16 + 8 == 24`; dst `alloca i64` gives `0 + 8 == 8`. So this comparison is
    # also the predicate's own MUTATION TEST — flipping `<=` to `<` rejects the
    # push! corpus at 6d, which is the evidence that 6d actually EVALUATES here
    # rather than being silently skipped by the guards just below. Worth knowing
    # before "tightening" it.
    #
    # SKIPPED, deliberately and narrowly, when the capacity is not provable
    # (`_root_scale === nothing`, i.e. a pointer parameter / global / phi / load
    # with no reservation IN THIS FUNCTION; or a RUNTIME-count alloca, `cap < 0`).
    # There is nothing to compare against in those cases and inventing a bound
    # would be worse than admitting the gap. An UNRESOLVABLE OFFSET off a
    # PROVABLE capacity is a different matter and fails loud — we know there is a
    # bound and cannot show the access respects it.
    for (side, side_v) in (("dst", dst_v), ("src", src_v))
        rs = _root_scale(side_v, names, ptr_cells)
        rs === nothing && continue                  # capacity unprovable
        rs[2] < 0 && continue                       # runtime-count reservation
        cap_bytes = rs[1] * rs[2]
        roff = _root_byte_offset(side_v)
        roff === nothing && _ir_error(inst,
            "$(cname): memcpy $(side) operand is derived from $(rs[3]) " *
            "(capacity $(cap_bytes) bytes), but its byte offset from that root " *
            "could not be resolved to a compile-time constant, so the copy " *
            "cannot be shown to stay INSIDE the object. Distinct allocation " *
            "roots imply disjoint ranges only for in-object ranges — BennettVM " *
            "bump-allocates, so a GEP that leaves its own object can land " *
            "inside the NEXT one and make a two-distinct-root memcpy genuinely " *
            "overlapping. Tracked in Bennett-8bys. " *
            "(Bennett-sy29 Predicate 6d, predicate `_root_byte_offset` / " *
            "`_root_scale`)")
        (roff >= 0 && roff + N <= cap_bytes) || _ir_error(inst,
            "$(cname): memcpy $(side) operand addresses bytes " *
            "[$(roff), $(roff + N)) of $(rs[3]), which reserves only " *
            "$(cap_bytes) byte(s) — the range leaves its own object. This is " *
            "REFUSED rather than clamped because BennettVM bump-allocates both " *
            "the arena and the stack: bytes past a reservation belong to the " *
            "NEXT allocation, so (a) the copy reads or writes another object, " *
            "and (b) the distinctness guard below stops implying disjointness " *
            "— two DISTINCT roots can name OVERLAPPING ranges once a GEP " *
            "leaves its object, and this arm's ascending per-cell " *
            "load-then-store miscopies an overlapping range. Tracked in " *
            "Bennett-8bys. (Bennett-sy29 Predicate 6d, predicate " *
            "`_root_byte_offset` / `_root_scale`)")
    end

    # Predicate 7: src and dst must be distinct ROOTS (memmove semantics).
    # GENERALISED by Bennett-sy29 from "same alloca" to "same root, whichever
    # kind" — see the overlap argument above. The alloca↔alloca message is kept
    # CHARACTER-IDENTICAL (`test_37mt:101` pins "same alloca"); an arena root on
    # either side gets its own text naming the enforcing predicate.
    if eff_dst_root === eff_src_root
        if arena_dst === nothing && arena_src === nothing
            _ir_error(inst,
                "$(cname): memcpy with src and dst rooted at the same alloca is " *
                "semantically memmove (overlapping or in-place copy). " *
                "Reversibility forbids destructive in-place overwrite. Tracked " *
                "in Bennett-8bys. (Bennett-37mt Phase 1 — distinct allocas only)")
        else
            _ir_error(inst,
                "$(cname): memcpy with src and dst rooted at the SAME " *
                "`julia.gc_alloc_obj` ARENA allocation is semantically " *
                "memmove (overlapping or in-place copy). The per-cell " *
                "decomposition this arm emits never reaches BennettVM's " *
                "runtime overlap check (that check lives in " *
                "`forward(::IntrinsicMemcpy)`, and no `IntrinsicMemcpy` is " *
                "emitted here), so proving disjointness at extraction is the " *
                "ONLY guard — and a shared root cannot be proven disjoint " *
                "without an alias analysis Bennett does not have. Contrast " *
                "Bennett-vau9: `memmove` MAY overlap and routes to " *
                "`IRCall(:memmove)` because BVM's `_copy_range!` snapshots the " *
                "src range first. Tracked in Bennett-8bys. " *
                "(Bennett-sy29 — generalised Predicate 7, distinct roots only)")
        end
    end

    # Predicate 8: both operands must have a known integer element width.
    # Bennett-ixiz (2026-05-16) lifted the prior `dst_ew == 8 && src_ew == 8`
    # gate; arbitrary equal integer element widths (8/16/32/64) are now
    # accepted. The new predicates 8b (same-width) and 8c (N is multiple of
    # ew_bytes) follow.
    #
    # Bennett-sy29: an ARENA side has FIXED cell width 64 (BennettVM ADR 0018
    # §A — a gc_alloc'd cell holds one Int64), and SKIPS the alloca-specific
    # `_alloca_elem_width_bits` probe: there is no `LLVMGetAllocatedType` for a
    # call result. Verbatim the vbv9 G4 structure.
    dst_ew = arena_dst !== nothing ? 64 : _alloca_elem_width_bits(dst_root)
    src_ew = arena_src !== nothing ? 64 : _alloca_elem_width_bits(src_root)
    if dst_ew == 0 || src_ew == 0
        _ir_error(inst,
            "$(cname): memcpy operand alloca has non-integer element type " *
            "(dst_ew=$dst_ew bits, src_ew=$src_ew bits — 0 indicates a " *
            "struct, ptr, nested-array, or non-integer ArrayType inner). " *
            "Bennett's wire model only supports flat integer-typed " *
            "allocas. Tracked in Bennett-8bys. (Bennett-37mt / Bennett-ixiz)")
    end

    # Predicate 8b (Bennett-ixiz): src and dst must have the same element
    # width. Cross-width memcpy requires implicit pack/unpack lowering and
    # a wider shadow-tape contract; out-of-scope for ixiz.
    dst_ew == src_ew || _ir_error(inst,
        "$(cname): memcpy cross-width src/dst (src=$src_ew bits, " *
        "dst=$dst_ew bits) is out-of-scope for Bennett-ixiz — requires " *
        "implicit pack/unpack lowering. Tracked in Bennett-8bys.")

    # Predicate 8c (Bennett-ixiz): N must be a whole multiple of element-
    # size bytes. Byte-granular tail copy (loading partial elements) is
    # out-of-scope.
    rem(N * 8, dst_ew) == 0 || _ir_error(inst,
        "$(cname): memcpy N=$N bytes is not a multiple of element size " *
        "$(div(dst_ew, 8)) bytes — byte-granular tail copy is " *
        "out-of-scope for Bennett-ixiz. Tracked in Bennett-8bys.")

    # Operand resolution: both operand SSA names must be in the table.
    haskey(names, dst_v.ref) || _ir_error(inst,
        "$(cname): memcpy dst pointer is not a named SSA value. " *
        "(Bennett-37mt Phase 1)")
    haskey(names, src_v.ref) || _ir_error(inst,
        "$(cname): memcpy src pointer is not a named SSA value. " *
        "(Bennett-37mt Phase 1)")
    dst_op = ssa(names[dst_v.ref])
    src_op = ssa(names[src_v.ref])

    # Bennett-land: carry-through tagging. If src alloca was previously
    # tagged as carrying synthetic-address bytes (via a prior memcpy
    # from a struct-with-ptr-field global), propagate the tag to dst.
    # This handles the HashMap::new pattern:
    #   memcpy %_3 ← @anon       (tags %_3 in global-src arm)
    #   memcpy %_2 ← %_3         (this arm: propagates tag to %_2)
    #   memcpy %_0 ← %_2         (this arm: propagates tag to %_0)
    # Without this propagation, a later load through %_2 / %_0 would
    # silently miscompile on the synth-address bytes.
    #
    # Bennett-sy29 §7.6: the set is keyed on `_LLVMRef`, which admits an ARENA
    # call ref just as well as an alloca ref, so the propagation is stated over
    # the EFFECTIVE roots rather than over alloca refs alone.
    #
    # *** THIS IS FUTURE-PROOFING, NOT A LIVE FIX — corrected under hostile
    # review (D3). Do not cite it as "the laundering hole is closed." ***
    #
    # The hazard it is shaped against is real in principle: vbv9's arena-dst
    # branch used to record NOTHING, so synth-address bytes could sit untracked
    # in an arena cell and an arena-src memcpy would LAUNDER them into an alloca,
    # defeating the `Bennett-land-ptrload` escape guard (which walks to ALLOCA
    # roots only, `_handle_load`). But that chain is UNREACHABLE TODAY, and the
    # reason is measured (reviewer probe `p8_launder`), not assumed:
    #
    #   `synth_ptr_provenance` is only ever populated for a ConstantStruct
    #   global, and such a global materialises as a BYTE stream — so `gw == 8`
    #   ALWAYS. An arena dst is fixed at `dst_ew == 64` (ADR 0018 §A). G6
    #   (`dst_ew == gw`) therefore fires FIRST, with the cross-width message,
    #   on every global→arena memcpy that could carry synth provenance. The
    #   land block below is never reached with `is_arena` true.
    #
    # So the branch cannot be exercised until either arena cells gain a byte
    # tier on the global-src path or synth provenance gains a 64-bit-element
    # source. It is kept because the arm should DECIDE rather than drift, and
    # because it is strictly stronger than the alternative (a u2kk-style
    # refusal) — but its value is that it will already be right when the
    # blocking predicate moves, not that it fixes something today.
    if eff_src_root in synth_ptr_allocas
        push!(synth_ptr_allocas, eff_dst_root)
    end

    # ---- Expansion: K element-granular quads ---------------------------------
    # (Bennett-ixiz) K = N / ew_bytes IRPtrOffset+IRPtrOffset+IRLoad+IRStore
    # quads. Each load/store carries the VALUE width (`dst_ew`, == `src_ew` by
    # Predicate 8b).
    #
    # Bennett-4y0d / Bennett-sy29 — THE ADDRESS/VALUE SPLIT, APPLIED PER SIDE.
    # The width a value is moved at and the scale an address is stamped at are
    # DIFFERENT NUMBERS, and HEAD conflated them by using `dst_ew` for all four
    # nodes. They coincide for the alloca↔alloca clientele by construction, and
    # they stop coinciding the moment either side is an arena root — which is
    # exactly the latent shape that kept the pre-4y0d vbv9 defect green behind
    # K=1 pins (at K=1 the only offset is 0, which is cell 0 under EVERY stamp,
    # so (SC)'s vacuity exemption hides the error).
    #
    # BYTE-IDENTITY FOR EVERY PRE-SY29 CLIENT, argued from the two functions'
    # definitions rather than from testing: `_root_scale` bottoms out at
    # `_alloca_reservation`, the SAME source of truth the alloca arm reserves
    # from. For an integer-typed alloca it returns that integer width, so
    # `8 * rs[1] == _alloca_elem_width_bits(root) == dst_ew`. Where the two could
    # disagree they are unreachable: a pointer-typed alloca gives
    # `_alloca_elem_width_bits == 0` and dies at Predicate 8; a nested-array or
    # non-integer alloca makes `_root_scale` return `nothing` and we fall back to
    # `dst_ew`, HEAD's value; a sub-byte width (`alloca i1`) fails
    # `_root_scale`'s `ew % 8 == 0` guard and also falls back.
    ew_bytes = div(dst_ew, 8)
    K = div(N, ew_bytes)
    ptr_ew_src = let rs = _root_scale(src_v, names, ptr_cells)
        rs === nothing ? src_ew : 8 * rs[1]
    end
    ptr_ew_dst = let rs = _root_scale(dst_v, names, ptr_cells)
        rs === nothing ? dst_ew : 8 * rs[1]
    end
    out = IRInst[]
    sizehint!(out, 4 * K)
    for k in 0:(K - 1)
        src_off = _auto_name(counter)
        dst_off = _auto_name(counter)
        tmp     = _auto_name(counter)
        push!(out, IRPtrOffset(src_off, src_op, k * ew_bytes, ptr_ew_src))
        push!(out, IRPtrOffset(dst_off, dst_op, k * ew_bytes, ptr_ew_dst))
        push!(out, IRLoad(tmp, ssa(src_off), dst_ew))
        push!(out, IRStore(ssa(dst_off), ssa(tmp), dst_ew))
    end
    return out
end

# ---- Bennett-qmv7 (2026-06-25, CW-D fdict critical path) ----
"""
    _handle_memcpy_gc_loaded(cname, inst, names, counter, ops, heap_dst, src_root)
        -> Vector{IRInst}

Bennett-qmv7: lower a SINGLE-ELEMENT memcpy whose DST is a runtime-indexed
`julia.gc_loaded` heap-Memory cell store (the `setindex!` value-store into a
Dict's keys/vals `Memory`). The dual of vbv9 (const-offset gc_alloc ARENA dst);
here the dst byte-offset is a RUNTIME SSA (`%off * STRIDE`), so we address by
the RAW element index, never the byte offset (the eln6-safe split done by
`_gc_loaded_dst_elem_ref`).

`heap_dst = (gc_loaded_base_ref, raw_index_ref, stride_bytes)` from
`_gc_loaded_dst_elem_ref`. `src_root` is the src alloca ref (or `nothing`).

Reached ONLY under `ptr_cells=true` (the caller gate). Emission reuses ONLY
existing IR nodes (IRVarGEP/IRLoad/IRStore — Rule 12); no new IR node, no BVM
ingest change for the store itself (the gc_loaded IRCall + its base resolution
are downstream BVM concerns, separate beads).

### Element-width contract (eln6, Rule 1)
The VALUE element width is the Memory element width = `stride_bytes*8` (the byte
stride the index `mul` scales by), NEVER the i8 dst-GEP source type and NEVER a
blind 64. CRUCIALLY it is NOT the src alloca's element width either: on the real
fdict root the src is the `setindex!` sret box (`alloca [2 x i64]`, so
`_alloca_elem_width_bits == 64`) accessed through a const-i8-GEP, but the stored
value is i8 — so the box width would mis-report 64 for an i8 store. The single
authoritative width is `N*8` (the memcpy byte count scaled to bits), which for a
single element equals `stride_bytes*8`. We require `N == stride_bytes` (one
element) so all three agree, and the resulting `value_ew` addresses cell `off`
at the correct width for EVERY Memory element type.

### Fail-loud matrix
  - src not alloca-backed (`src_root === nothing`)            → reject
  - N (memcpy bytes) != stride_bytes (multi-element / sub-elt)→ reject
  - value ew = N*8 ∉ {8,16,32,64}                             → reject
  - gc_loaded base / raw index / src not a named SSA value    → reject
"""
function _handle_memcpy_gc_loaded(cname::AbstractString, inst::LLVM.Instruction,
                                  names::Dict{_LLVMRef, Symbol}, counter::Ref{Int},
                                  ops,
                                  heap_dst::Tuple{_LLVMRef, _LLVMRef, Int},
                                  src_root::Union{Nothing, _LLVMRef})
    dst_v = ops[1]
    src_v = ops[2]
    n_v   = ops[3]
    N     = _const_int_as_int(n_v)   # Predicates 1-4 (caller) already validated.

    gcl_ref, off_ref, stride_bytes = heap_dst

    # The src must be alloca-backed so the IRLoad reads from a valid named SSA
    # value box (the setindex! sret field).
    src_root === nothing && _ir_error(inst,
        "$(cname): gc_loaded heap-Memory memcpy src is not alloca-backed — " *
        "the value box (a setindex! sret field) must root at an alloca. " *
        "(Bennett-qmv7)")

    # Single-element only: a setindex! stores exactly one element, so the memcpy
    # byte count N must equal the Memory's byte stride. A multi-element memcpy
    # (N != stride) into a heap Memory would need per-element cell-stride
    # emission and does not arise on the fdict root. Enforcing N == stride_bytes
    # makes the value width unambiguous (value_ew = N*8 = stride_bytes*8).
    N == stride_bytes || _ir_error(inst,
        "$(cname): gc_loaded heap-Memory memcpy N=$(N) bytes != single " *
        "element size $(stride_bytes) bytes (the byte stride from " *
        "`mul %off, $(stride_bytes)`) — multi-element / sub-element heap-Memory " *
        "memcpy is out of scope (the fdict setindex! root stores exactly one " *
        "element). Tracked in Bennett-qmv7-multi. (Bennett-qmv7)")

    # The value element width = the Memory element width = N*8 bits (== the byte
    # stride scaled to bits). NEVER the i8 dst-GEP type, NEVER the src box width
    # (which is the [2 x i64] sret box = 64, not the i8/i16/... stored value),
    # NEVER a blind 64. This is the single eln6-safe width for the heap cell.
    value_ew = N * 8
    value_ew ∈ (8, 16, 32, 64) || _ir_error(inst,
        "$(cname): gc_loaded heap-Memory memcpy element width $(value_ew) bits " *
        "(= N*8, N=$(N)) ∉ {8,16,32,64} — only byte/half/word/dword heap-cell " *
        "stores are modelled. (Bennett-qmv7)")

    # The gc_loaded base and the raw element index must be named SSA values
    # (they are: the gc_loaded CALL and the `sub %k, 1` index both lower
    # normally before this memcpy in block order — empirically verified).
    haskey(names, gcl_ref) || _ir_error(inst,
        "$(cname): gc_loaded heap-Memory base (julia.gc_loaded result) is " *
        "not a named SSA value. (Bennett-qmv7)")
    haskey(names, off_ref) || _ir_error(inst,
        "$(cname): gc_loaded heap-Memory element index is not a named SSA " *
        "value. (Bennett-qmv7)")
    haskey(names, src_v.ref) || _ir_error(inst,
        "$(cname): gc_loaded heap-Memory memcpy src pointer is not a named " *
        "SSA value. (Bennett-qmv7)")

    base_op = ssa(names[gcl_ref])
    idx_op  = ssa(names[off_ref])
    src_op  = ssa(names[src_v.ref])

    # Emit: fresh element-address GEP at the RAW index (cell `off`, eln6-safe) +
    # load the value out of the alloca-backed src + store it into the heap cell.
    addr = _auto_name(counter)
    tmp  = _auto_name(counter)
    return IRInst[
        IRVarGEP(addr, base_op, idx_op, value_ew),
        IRLoad(tmp, src_op, value_ew),
        IRStore(ssa(addr), ssa(tmp), value_ew),
    ]
end

# ---- Bennett-doih (2026-05-16, Bennett-8bys sub-bead under Bennett-hao Phase 3) ----
# Global-pointer src memcpy: copies bytes from a `[N x iM]` ConstantDataArray
# global into a fresh alloca destination. Lowers to K element-granular
# IRPtrOffset+IRStore(iconst) chunks pulling per-element values from the
# `parsed.globals` dict (extracted in `module_walk.jl::_extract_const_globals`).
#
# Scope (MVP — intentionally narrow per CLAUDE.md §11 / "scope it tight"
# lesson from Bennett-ixiz):
#   - src is either a direct global reference OR a const-GEP `getelementptr
#     i8, ptr @g, i32 OFF` whose base is a global. Variable-GEP src is
#     rejected with `Bennett-doih-vargep`.
#   - global must appear in `parsed.globals` (i.e. be a `ConstantDataArray`
#     of integer elements, post-_extract_const_globals filtering).
#     ConstantStruct globals → `Bennett-doih-struct`. External / opaque
#     initializers → `Bennett-doih-external` / `Bennett-doih-opaque`.
#   - dst is a fresh alloca with the SAME integer element width as the
#     global (mirrors `_handle_memcpy_arm`'s predicate 8b). Cross-width
#     (`alloca i64` dst + `[N x i8]` global, or vice versa) → `Bennett-
#     doih-wide`. The follow-up bead `Bennett-doih-wide` covers byte-
#     packing for cross-width.
#   - N (byte count) must be a multiple of `gw/8` AND fit within the
#     global's available bytes after applying any const-GEP offset.
#   - dst alloca must be FRESH per `_alloca_is_fresh` (closes the 37mt
#     inherited hazard — pre-doih the alloca-i8 memcpy path never had
#     this gate, but doih is the first memcpy variant we're shipping
#     with a constant source-side, so the freshness contract matters
#     for the same §1 reason as Bennett-9nwt's case C).

"""
    _src_reaches_global(val) -> Bool

Cheap predicate: returns `true` iff `val` is a direct global reference
or a ConstantExpr GEP whose base operand is a global. Used by
`_handle_memcpy_arm`'s predicate 5b to decide whether to dispatch to
the doih global-src arm. The full unpacking (global ref + byte offset)
happens in `_global_root_and_offset` once we're inside the doih arm.
"""
function _src_reaches_global(val::LLVM.Value)::Bool
    val.ref == C_NULL && return false
    LLVM.API.LLVMIsAGlobalVariable(val.ref) != C_NULL && return true
    # Const-GEP wrapping a global: kind == ConstantExprValueKind AND
    # the constexpr's opcode is `getelementptr`. Operand 1 of that
    # GEP is the base — recurse one level (defence-in-depth: nested
    # const-GEPs are uncommon but legal).
    if val isa LLVM.ConstantExpr
        opc = LLVM.API.LLVMGetConstOpcode(val.ref)
        if opc == LLVM.API.LLVMGetElementPtr
            gep_ops = LLVM.operands(val)
            length(gep_ops) >= 1 || return false
            return _src_reaches_global(gep_ops[1])
        end
    end
    # Runtime GEP (Instruction) whose base reaches a global. We still
    # route to the doih arm so it can fail-loud with a precise
    # `Bennett-doih-vargep` breadcrumb; falling through to predicate 6
    # would mis-categorise the failure as "not alloca-backed" + 37mt.
    if val isa LLVM.Instruction && LLVM.opcode(val) == LLVM.API.LLVMGetElementPtr
        gep_ops = LLVM.operands(val)
        length(gep_ops) >= 1 || return false
        return _src_reaches_global(gep_ops[1])
    end
    return false
end

"""
    _global_root_and_offset(val) -> Union{Nothing, Tuple{_LLVMRef, Int}}

Walk a pointer SSA value back to its underlying global, accumulating
any const-GEP byte offsets along the way. Returns `(global_ref,
byte_offset)` or `nothing` if the chain doesn't bottom out in a global
or if a variable-index GEP is encountered.

Currently handles:
  - direct global reference → (ref, 0)
  - const-GEP `getelementptr i8, ptr @g, i32 OFF` → (ref, OFF)
  - const-GEP through nested ConstantExpr — recurses

Variable-index GEPs (any GEP index that isn't a ConstantInt) return
`nothing`; the caller (`_handle_memcpy_global_src`) fails loud with a
`Bennett-doih-vargep` breadcrumb. Multi-index GEPs through a `[N x iM]`
ArrayType are flattened: the element index is multiplied by the element
byte width.
"""
function _global_root_and_offset(val::LLVM.Value, depth::Int=0
                                 )::Union{Nothing, Tuple{_LLVMRef, Int}}
    depth > 8 && return nothing
    val.ref == C_NULL && return nothing
    if LLVM.API.LLVMIsAGlobalVariable(val.ref) != C_NULL
        return (val.ref, 0)
    end
    if val isa LLVM.ConstantExpr &&
       LLVM.API.LLVMGetConstOpcode(val.ref) == LLVM.API.LLVMGetElementPtr
        gep_ops = LLVM.operands(val)
        length(gep_ops) >= 2 || return nothing
        base = gep_ops[1]
        # Pointee type of the GEP — accessed via the opaque-ptr GEP
        # source-element-type API. For `getelementptr i8, ptr @g, ...`
        # this is i8 (so per-index stride = 1 byte). For `getelementptr
        # [N x i32], ptr @g, i32 0, i32 K` this is the array type
        # (first index is 0 stepping past the whole array; second
        # index K * 4 bytes).
        srcty = try
            LLVM.LLVMType(LLVM.API.LLVMGetGEPSourceElementType(val.ref))
        catch e
            e isa InterruptException && rethrow()
            return nothing
        end
        # Compute byte offset from index operands.
        idx_off = 0
        for i in 2:length(gep_ops)
            iv = gep_ops[i]
            iv isa LLVM.ConstantInt || return nothing  # variable GEP
            ival = Int(LLVM.API.LLVMConstIntGetSExtValue(iv.ref))
            if i == 2
                # First index strides over `srcty`. We accept either:
                # (a) `srcty` is integer iM → stride = M/8 (e.g.
                #     `getelementptr i8, ptr @g, i32 4` → 4 bytes).
                # (b) `srcty` is ArrayType — first index must be 0
                #     (stepping past the whole array doesn't make
                #     sense for a memcpy source). Non-zero outer
                #     index → reject (multi-array GEP exotica).
                if srcty isa LLVM.IntegerType
                    stride = div(LLVM.width(srcty), 8)
                    idx_off += ival * stride
                elseif srcty isa LLVM.ArrayType
                    ival == 0 || return nothing
                else
                    return nothing
                end
            else
                # Second+ index: must be into the inner (array) element.
                if srcty isa LLVM.ArrayType
                    inner = LLVM.eltype(srcty)
                    inner isa LLVM.IntegerType || return nothing
                    stride = div(LLVM.width(inner), 8)
                    idx_off += ival * stride
                else
                    return nothing
                end
            end
        end
        sub = _global_root_and_offset(base, depth + 1)
        sub === nothing && return nothing
        (gref, gbase_off) = sub
        return (gref, gbase_off + idx_off)
    end
    return nothing
end

"""
    _handle_memcpy_global_src(cname, inst, names, counter, ops, globals) -> Vector{IRInst}

Bennett-doih global-src memcpy arm. Pre-conditions verified by
`_handle_memcpy_arm` (predicates 1-4 and 5a). This arm runs G1-G9:

  G1. dst SSA must be in the names table
  G2. dst is NOT a global (defensive — caller's 5a already covers)
  G3. dst traces to an alloca via `_alloca_root_ref` — OR, under the
      closed-world `ptr_cells` gate, to a `julia.gc_alloc_obj` ARENA call via
      `_gc_alloc_root_ref` (Bennett-vbv9; sets `is_arena`), OR to a pointer
      PARAMETER cell via `_param_ptr_root_ref` (Bennett-u2kk; sets `is_param`).
  G4. dst alloca elem_w is a non-zero integer (ALLOCA only; ARENA/PARAM → cell
      width 64, ADR 0018 §A — G4 is SKIPPED)
  G5. src reaches a global; that global is in `globals` dict
  G6. dst_ew == global_ew (no cross-width packing in MVP — for the ARENA/PARAM
      dst this constrains the src global to 64-bit: a non-64-bit global into a
      64-bit cell FAILS LOUD here)
  G7. src byte offset and N are multiples of ew_bytes (cell-aligned for ARENA/PARAM)
  G8. N + src_byte_off ≤ available global bytes
  G9. dst alloca is fresh per `_alloca_is_fresh` (ALLOCA only; ARENA → SKIPPED,
      gc_alloc zero-inits + distinct field offsets, STEP 0c; PARAM → SKIPPED,
      destructive live-field overwrite reversed by BVM's history tape, not by
      freshness — Bennett-u2kk REVERSIBILITY JUSTIFICATION at the G4 branch)

Emission shape (mirror of Bennett-9nwt case C; IDENTICAL for ALLOCA/ARENA/PARAM):
K element-granular `IRPtrOffset + IRStore(iconst, dst_ew)` pairs where each
iconst is the k-th element of the global at the requested byte offset,
K = N / ew_bytes. For the ARENA/PARAM dst, dst_ew=64 ⇒ K=N/8 cell-granular stores.
"""
function _handle_memcpy_global_src(cname::AbstractString, inst::LLVM.Instruction,
                                   names::Dict{_LLVMRef, Symbol},
                                   counter::Ref{Int}, ops,
                                   globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}};
                                   synth_ptr_provenance::Set{Tuple{Symbol, Int, Int}}=
                                       Set{Tuple{Symbol, Int, Int}}(),
                                   synth_ptr_allocas::Set{_LLVMRef}=Set{_LLVMRef}(),
                                   ptr_cells::Bool=false)
    dst_v = ops[1]
    src_v = ops[2]
    n_v   = ops[3]
    N = _const_int_as_int(n_v)  # already validated to be ConstantInt>=0 by caller

    # G1: dst SSA must be in the names table.
    haskey(names, dst_v.ref) || _ir_error(inst,
        "$(cname): memcpy dst pointer is not a named SSA value. " *
        "(Bennett-doih)")

    # G2: dst not a global (defensive — caller's 5a already rejected).
    LLVM.API.LLVMIsAGlobalVariable(dst_v.ref) == C_NULL || _ir_error(inst,
        "$(cname): internal — dst is a global but caller's 5a should " *
        "have rejected it already. (Bennett-doih internal invariant)")

    # G3: dst must trace to an alloca (direct or const-GEP) — OR, under the
    # closed-world `ptr_cells` gate (Bennett-vbv9), to a `julia.gc_alloc_obj`
    # ARENA allocation (the Julia typed-GC bump cell — BennettVM ADR 0021 D3).
    # The arena root is consulted ONLY under ptr_cells: on the circuit path a
    # non-alloca dst stays FAIL-LOUD with the UNCHANGED doih message (byte-
    # identical to pre-vbv9), because the circuit model has no gc_alloc cell.
    dst_root = _alloca_root_ref(dst_v)
    arena_root = (dst_root === nothing && ptr_cells) ?
        _gc_alloc_root_ref(dst_v) : nothing
    # Bennett-u2kk (2026-06): the THIRD G3 root — a const-offset GEP off a
    # function POINTER PARAMETER cell (the Dict struct-by-ref param `h::Dict`).
    # Consulted ONLY when both alloca and arena roots miss, and ONLY under
    # ptr_cells (the BVM cell model — see the reversibility note at G4).
    param_root = (dst_root === nothing && arena_root === nothing && ptr_cells) ?
        _param_ptr_root_ref(dst_v) : nothing
    if dst_root === nothing && arena_root === nothing && param_root === nothing
        _ir_error(inst,
            "$(cname): memcpy dst operand is not alloca-backed (or " *
            "alloca-backed via a const-offset GEP) on the global-src path. " *
            "Pointer phi/select/parameter dst not handled. Tracked in " *
            "Bennett-8bys. (Bennett-doih)")
    end
    is_arena = arena_root !== nothing
    is_param = param_root !== nothing

    # G4: dst element width. ARENA dst → fixed cell width 64 (ADR 0018 §A: a
    # gc_alloc'd cell is one Int64 VM cell). The arena branch SKIPS the
    # alloca-specific `_alloca_elem_width_bits` probe (there is no
    # LLVMGetAllocatedType for a call result) and the G9 freshness check below
    # (gc_alloc zero-inits the object and the 5 fdict field-init memcpys hit
    # DISTINCT, non-overlapping byte offsets — empirically verified
    # Bennett-vbv9 STEP 0c — so no destructive overwrite is possible; a precise
    # freshness guard for the general arena case is deferred to a follow-up
    # bead). ALLOCA dst → unchanged G4/G9 path below.
    #
    # PARAM dst (Bennett-u2kk) → ALSO fixed cell width 64 (ADR 0018 §A: a
    # caller-supplied pointer-param cell is one Int64 VM cell), and ALSO SKIPS
    # the alloca-specific `_alloca_elem_width_bits` probe (no
    # LLVMGetAllocatedType for an Argument) and the G9 freshness gate. But the
    # reasoning is DIFFERENT and worth pinning, because the freshness skip is
    # NOT vbv9's STEP-0c "fresh dst" argument:
    #
    #   *** REVERSIBILITY JUSTIFICATION (the crux) ***
    #   The param-field write is a DESTRUCTIVE OVERWRITE of a LIVE field — the
    #   caller's Dict already holds a value at `idxfloor`/`ndel`/`maxprobe`, so
    #   the dst is NOT fresh and vbv9's freshness argument does NOT apply (do
    #   NOT claim it). It is nevertheless reversible UNDER ptr_cells because the
    #   BVM (`target=:reversible_vm`) logs every cell store on its Bennett-1973
    #   history tape `(cell, pre-image)` and undoes it on reversal. Freshness is
    #   a CIRCUIT-MODEL artifact (the circuit path has no tape, so it cannot
    #   reverse a destructive overwrite) — which is exactly why G9 is skipped
    #   here AND why the `ptr_cells=false` circuit path KEEPS failing loud at the
    #   G3 "not alloca-backed" wall above (param_root is ptr_cells-gated). This
    #   memcpy lowers to the IDENTICAL `IRPtrOffset + IRStore` shape that the
    #   proven plain `IRStore`-into-param-field path (setindex! field stores)
    #   already produces under ptr_cells with NO freshness guard — it adds ZERO
    #   new reversibility surface over what already works.
    if is_arena || is_param
        dst_ew = 64
    else
        # G4: dst alloca must have a non-zero integer element width.
        dst_ew = _alloca_elem_width_bits(dst_root)
        dst_ew == 0 && _ir_error(inst,
            "$(cname): memcpy dst alloca has non-integer element type " *
            "(dst_ew=0 indicates struct, ptr, nested-array, or non-integer " *
            "ArrayType inner). Tracked in Bennett-8bys. (Bennett-doih)")
    end

    # G5: src reaches a global, and the global is in the globals dict.
    src_unpacked = _global_root_and_offset(src_v)
    src_unpacked === nothing && _ir_error(inst,
        "$(cname): memcpy src reaches a global via a variable-index " *
        "GEP (runtime indexing) or an exotic GEP shape. doih MVP " *
        "supports only direct globals and const-byte-offset GEPs of " *
        "globals. Tracked in Bennett-doih-vargep follow-up " *
        "(Bennett-ui4f). (Bennett-doih)")
    (src_gref, src_byte_off) = src_unpacked
    src_byte_off >= 0 || _ir_error(inst,
        "$(cname): memcpy src const-GEP yields a negative byte offset " *
        "($src_byte_off) — out-of-bounds read on the global. (Bennett-doih)")
    gname = Symbol(LLVM.name(LLVM.Value(src_gref)))
    haskey(globals, gname) || _ir_error(inst,
        "$(cname): memcpy src global @$gname is not extractable as a " *
        "constant integer byte stream. Likely causes: (a) the " *
        "initializer is a ConstantStruct with a non-materialisable " *
        "field — Bennett-zxhg-ptrfield covers the FloatType / " *
        "VectorType / opaque / IntegerType-wider-than-64 residuals; " *
        "ptr-typed fields now materialise as synthetic 64-bit " *
        "compile-time addresses (Bennett-land), so a ptr field per " *
        "se no longer hits this branch — but the new " *
        "Bennett-land-ptrload escape guard fails loud downstream if " *
        "any loaded byte traces back to such synthetic-address bytes. " *
        "Bennett-land also still rejects ptr fields with non-zero " *
        "addrspace (Bennett-land-addrspace), inttoptr-of-const " *
        "operands (Bennett-land-inttoptr), and undef/unresolvable " *
        "ptr identity. (b) the global is an external declaration " *
        "with no initializer — tracked in Bennett-doih-external " *
        "(covered by Bennett-zxhg); (c) the initializer is an opaque " *
        "kind (GlobalAlias, ConstantVector, etc.) — tracked in " *
        "Bennett-doih-opaque (covered by Bennett-zxhg). Check " *
        "`parsed.globals` to see what was extracted. (Bennett-doih)")
    (gdata, gw) = globals[gname]

    # G6: same-width invariant. Cross-width packing deferred to
    # Bennett-doih-wide.
    dst_ew == gw || _ir_error(inst,
        "$(cname): memcpy cross-width src/dst (global @$gname is " *
        "[N x i$gw], dst alloca is i$dst_ew). doih MVP requires " *
        "matching element widths; byte-packing wider globals into " *
        "narrower dst (or vice versa) is deferred to " *
        "Bennett-doih-wide (Bennett-epfe). (Bennett-doih)")

    # G7: byte-offset and N must be multiples of ew_bytes.
    ew_bytes = div(dst_ew, 8)
    ew_bytes >= 1 || _ir_error(inst,
        "$(cname): internal — dst_ew=$dst_ew bits gives ew_bytes=0. " *
        "(Bennett-doih internal invariant)")
    rem(src_byte_off, ew_bytes) == 0 || _ir_error(inst,
        "$(cname): memcpy src const-GEP byte offset $src_byte_off is " *
        "not a multiple of element size $ew_bytes bytes — sub-element " *
        "alignment not supported. Tracked in Bennett-doih-wide " *
        "(Bennett-epfe). (Bennett-doih)")
    rem(N, ew_bytes) == 0 || _ir_error(inst,
        "$(cname): memcpy N=$N bytes is not a multiple of element " *
        "size $ew_bytes bytes — byte-granular tail copy on the " *
        "global-src path is out of scope. Tracked in " *
        "Bennett-doih-wide (Bennett-epfe). (Bennett-doih)")

    # G8: N + src_byte_off must fit within the global's bytes.
    avail_bytes = length(gdata) * ew_bytes
    src_byte_off + N <= avail_bytes || _ir_error(inst,
        "$(cname): memcpy reads $N bytes starting at offset $src_byte_off " *
        "from global @$gname which has only $avail_bytes available " *
        "bytes ($(length(gdata)) elements × $ew_bytes bytes). " *
        "Out-of-bounds read. (Bennett-doih)")

    # G9: dst alloca must be fresh (no prior IR-visible writes within
    # the same basic block). Reuses the Bennett-9nwt helper. SKIPPED for the
    # arena dst (Bennett-vbv9): gc_alloc zero-inits the object and the fdict
    # field-init memcpys hit distinct, non-overlapping byte offsets (STEP 0c),
    # so no destructive overwrite is possible; `_alloca_is_fresh` is also
    # alloca-specific (it walks back to an alloca root, which an arena dst
    # lacks). A precise arena-freshness guard is deferred to a follow-up bead.
    # SKIPPED for the PARAM dst too (Bennett-u2kk): the write IS a destructive
    # overwrite of a live field, but it is reversed by BVM's history tape, not
    # by a freshness precondition (see the REVERSIBILITY JUSTIFICATION at G4);
    # and `_alloca_is_fresh` is alloca-specific (it walks to an alloca root,
    # which a param dst lacks).
    if !is_arena && !is_param
        _alloca_is_fresh(dst_root, inst) || _ir_error(inst,
            "$(cname): memcpy dst alloca has prior IR-visible writes within " *
            "this basic block (non-fresh dst) on the global-src path. " *
            "Reversibility forbids destructive overwrite without first " *
            "uncomputing the existing slot bits. Tracked in " *
            "Bennett-8bys-uncompute. (Bennett-doih)")
    end

    # ---- Bennett-land: tag dst alloca if any synth-ptr provenance ----
    # If the source global has any synth_ptr_provenance entries, mark
    # the dst alloca as "carries synthetic-address bytes" so the
    # downstream load-escape guard at `_handle_load` can fail loud
    # (`Bennett-land-ptrload`) when those bytes are read back as a
    # pointer/integer for arithmetic, comparison, or dereference. The
    # MVP guard is alloca-level coarse (any load from this alloca that
    # isn't piped into another memcpy fails loud); byte-precise overlap
    # analysis is tracked in `Bennett-land-precise-escape`. SKIPPED for the
    # arena dst (Bennett-vbv9): the synth-ptr-alloca set keys on alloca refs;
    # arena bytes are tracked under the BennettVM cell model, not this set.
    # SKIPPED/REJECTED for the PARAM dst (Bennett-u2kk): the `synth_ptr_allocas`
    # set keys on ALLOCA refs, so it CANNOT track a param-cell field. Rather than
    # silently drop the load-escape guard (which would let synthetic-address
    # bytes flow into a param cell undetected), FAIL LOUD — conservative per
    # Rule 1. (`_j_const#N` are plain integers, so rehash! never trips this; but
    # the guard must not be silently weakened.)
    if is_param
        any(p -> p[1] === gname, synth_ptr_provenance) && _ir_error(inst,
            "$(cname): synth-address bytes (from global @$gname) into a " *
            "param-cell field cannot be tracked by the alloca-keyed land " *
            "guard (synth_ptr_allocas keys on alloca refs, not param cells). " *
            "Tracked in Bennett-land-param / 8bys follow-up. (Bennett-u2kk)")
    elseif any(p -> p[1] === gname, synth_ptr_provenance)
        # Bennett-sy29 §7.6 option (a): the ARENA root is recorded too. Pre-sy29
        # this branch was `!is_arena && …`, i.e. an arena dst recorded NOTHING.
        # `synth_ptr_allocas` is a `Set{_LLVMRef}` and admits a
        # `julia.gc_alloc_obj` call ref unchanged; the load guard walks to ALLOCA
        # roots only, so recording the arena root is inert on its own and becomes
        # load-bearing exactly when the sy29 arm propagates it onto an alloca.
        #
        # *** FUTURE-PROOFING, NOT A LIVE FIX — corrected under hostile review
        # (D3). The `is_arena` case here is UNREACHABLE TODAY, and measurably so
        # (reviewer probe `p8_launder`): `synth_ptr_provenance` is populated only
        # for a ConstantStruct global, which materialises as a BYTE stream, so
        # `gw == 8` always; an arena dst is fixed at `dst_ew == 64`; and G6
        # (`dst_ew == gw`, above) therefore rejects every such memcpy with the
        # cross-width message BEFORE control reaches this block. Kept so the arm
        # is already right when that blocking predicate moves — not because it
        # closes a live hole.
        #
        # The `is_param` branch immediately above is a PRE-EXISTING instance of
        # the same unreachability (its `_ir_error` cannot fire for the same G6
        # reason). Noted, deliberately NOT changed here — it is u2kk's territory
        # and its refusal is the conservative direction anyway.
        push!(synth_ptr_allocas, is_arena ? arena_root : dst_root)
    end

    # ---- Emission: K element-granular IRPtrOffset + IRStore(iconst) ----
    # K = N / ew_bytes; each iconst is the source element at index
    # (src_byte_off / ew_bytes + k). Cast UInt64 → Int via reinterpret
    # to preserve the bit pattern for high-bit-set values (e.g. signed
    # i64 negative constants stored unsigned in the globals dict).
    dst_op = ssa(names[dst_v.ref])
    K = div(N, ew_bytes)
    src_elem_off = div(src_byte_off, ew_bytes)
    # Bennett-4y0d / Bennett-bvmd: the ADDRESS stamp and the ELEMENT width are
    # two different things and were conflated here. `dst_ew` is the width of the
    # value each store writes (64 for an arena/param cell, the alloca's element
    # width otherwise) and must NOT change. `ptr_ew` is the bytes-per-cell SCALE
    # of the destination's allocation root, which is what BennettVM divides the
    # byte offset by. For an ALLOCA dst the two coincide by construction (both
    # come from the same reservation), and for a scale-unknown PARAM dst the
    # fallback is 64 — so this is byte-identical everywhere except the ARENA dst.
    # There, `_alloc_cells(::IntrinsicGCAlloc)` reserves BYTE cells, so element k
    # belongs at cell `dst + 8k`, not `dst + k`. At K == 1 the only offset is 0,
    # which is cell 0 under EVERY stamp — which is exactly why the shipped
    # `test_vbv9_arena_memcpy.jl` K=1 pins were green over a latent defect.
    ptr_ew = let rs = _root_scale(dst_v, names, ptr_cells)
        rs === nothing ? dst_ew : 8 * rs[1]
    end
    out = IRInst[]
    sizehint!(out, 2 * K)
    for k in 0:(K - 1)
        dst_off = _auto_name(counter)
        word = gdata[src_elem_off + k + 1]  # 1-based indexing
        # Cast to signed Int via reinterpret (preserves bit pattern).
        ival = reinterpret(Int64, word) % Int
        push!(out, IRPtrOffset(dst_off, dst_op, k * ew_bytes, ptr_ew))
        push!(out, IRStore(ssa(dst_off), iconst(ival), dst_ew))
    end
    return out
end

# ---- Bennett-9nwt (Bennett-hao Phase 2) memset helpers ----

"""
    _alloca_is_fresh(alloca_ref, memset_inst) -> Bool

Conservative intra-block freshness check (Bennett-9nwt, option γ).
Returns `true` iff, walking forward through the basic block from the
alloca instruction to (but not including) `memset_inst`, no intervening
instruction writes through a pointer that traces back to `alloca_ref`.

Returns `false` (conservative non-fresh) when:
  - `alloca_ref` is in a different basic block from `memset_inst`
    (cross-block freshness needs dominance analysis we don't have)
  - any `Store` between alloca and memset has a pointer operand whose
    `_alloca_root_ref` chain reaches `alloca_ref`
  - any `Store` whose pointer operand has no resolvable alloca root
    (pointer phi/select/parameter — we can't prove non-aliasing, so
    treat as a possible write to `alloca_ref`)
  - any `Call` to `llvm.memcpy.*` / `llvm.memset.*` / `llvm.memmove.*`
    whose dst arg traces back to `alloca_ref`
  - any `Call` to a non-benign function with `alloca_ref`'s pointer
    (or a GEP thereof) appearing in any argument position

This is the predicate-12 gate for the c≠0 path in
`_handle_memset_arm`. The c==0 path takes a separate fast-track that
preserves pre-9nwt benign-allowlist behaviour for unaudited Julia
frontend code paths (acknowledged §1 hazard for c=0 non-fresh; tracked
under Bennett-8bys-uncompute).
"""
function _alloca_is_fresh(alloca_ref::_LLVMRef, memset_inst::LLVM.Instruction)::Bool
    alloca_inst = LLVM.Instruction(alloca_ref)
    LLVM.parent(alloca_inst) === LLVM.parent(memset_inst) || return false

    seen_alloca = false
    for inst in LLVM.instructions(LLVM.parent(memset_inst))
        if !seen_alloca
            inst === alloca_inst && (seen_alloca = true)
            continue
        end
        inst === memset_inst && return true
        opc = LLVM.opcode(inst)

        if opc == LLVM.API.LLVMStore
            ptr_v = LLVM.operands(inst)[2]
            root = _alloca_root_ref(ptr_v)
            root === nothing && return false      # opaque ptr — assume aliases
            root === alloca_ref && return false   # writes our slot
            continue
        end

        if opc == LLVM.API.LLVMCall
            call_ops = LLVM.operands(inst)
            n_call_ops = length(call_ops)
            n_call_ops >= 1 || continue
            cname = try LLVM.name(call_ops[n_call_ops]) catch; "" end
            if startswith(cname, "llvm.memcpy.") ||
               startswith(cname, "llvm.memset.") ||
               startswith(cname, "llvm.memmove.")
                root = _alloca_root_ref(call_ops[1])
                root === alloca_ref && return false
                continue
            end
            # Pure / annotation intrinsics with no memory effect: skip.
            if startswith(cname, "llvm.lifetime.") ||
               startswith(cname, "llvm.dbg.") ||
               startswith(cname, "llvm.assume") ||
               startswith(cname, "llvm.experimental.noalias.scope.decl") ||
               startswith(cname, "llvm.invariant.")
                continue
            end
            # Unknown call: if any arg traces to our alloca, conservatively reject.
            for i in 1:(n_call_ops - 1)
                root = _alloca_root_ref(call_ops[i])
                root === alloca_ref && return false
            end
            continue
        end
        # Loads, GEPs, arithmetic, casts: pure with respect to memory writes.
    end
    return false
end

"""
    _broadcast_byte_to_width(c::Int, ew::Int) -> Int

Bennett-ixiz: replicate the low 8 bits of `c` across `ew` bits, so an
ew-bit IRStore with the returned constant has the same byte-wise effect
as `memset(_, c, ew/8, _)`. E.g. `_broadcast_byte_to_width(0xAB, 64)
→ 0xABABABABABABABAB` packed into an Int.

`ew` must be a power-of-2 multiple of 8 (8/16/32/64). The returned Int
holds the low `ew` bits; for `ew == 64` the result may be negative
when the high bit is set (e.g. c=0xAB gives 0xABABABABABABABAB which is
-0x5454545454545455 as a signed Int64 — that is the correct in-memory
bit pattern and round-trips via simulate).
"""
function _broadcast_byte_to_width(c::Int, ew::Int)::Int
    c_u8 = UInt8(c & 0xff)
    out = UInt64(0)
    for k in 0:(div(ew, 8) - 1)
        out |= UInt64(c_u8) << (k * 8)
    end
    if ew >= 64
        return reinterpret(Int64, out) % Int
    end
    return Int(out & ((UInt64(1) << ew) - UInt64(1)))
end

"""
    _handle_memset_arm(cname, inst, names, counter, ops) -> Vector{IRInst}

Bennett-9nwt Phase 2: const-c const-N memset on alloca-i8-backed
destination. Two green cases:

  - Case A (c == 0, any dst): silent drop (`IRInst[]`). Preserves
    pre-9nwt benign-allowlist behaviour for Julia GC-frame zeroing
    patterns. NO alloca/freshness check on this path; tightening would
    risk regressing unaudited Julia frontend output. Acknowledged §1
    hazard for c=0 on non-fresh dst — tracked under
    Bennett-8bys-uncompute. Also covers *volatile* c=0 memsets
    (Bennett-8su4): Julia's heap-allocating frontend zero-inits the GC
    frame with a volatile c=0 memset, which drops here as a no-op.

  - Case C (c != 0, fresh alloca-i8 dst): emit N byte-granular
    `IRPtrOffset + IRStore(ConstOperand(c), 8)` pairs.

All other shapes fail loud naming Bennett-8bys (catch-all) or
Bennett-8bys-uncompute (non-fresh dst with c≠0).

Predicate cascade (earliest mismatch → most actionable error):

  1. addrspace 0 — `llvm.memset.p0.*` or `llvm.memset.inline.p0.*`
  2. operand count >= 5 (4 args + callee)
  3. isvolatile (4th op) is a ConstantInt (malformed-IR guard)
  4. fill byte c (2nd op) is ConstantInt
  5. byte count N (3rd op) is ConstantInt
  6. N >= 0
  7. N == 0 → return `IRInst[]` (LangRef no-op)
  8. c == 0 → return `IRInst[]` (case A — preserve broad tolerance)
  8b. isvolatile value == 0 (volatile c!=0 rejected; volatile c=0
      already dropped at step 8 — Bennett-8su4)
  9. dst is named SSA in `names`
 10. dst is not a global variable
 11. dst alloca-rooted via `_alloca_root_ref`
 12. alloca elem_w == 8
 13. dst alloca is fresh per `_alloca_is_fresh` (option γ)
"""
function _handle_memset_arm(cname::AbstractString, inst::LLVM.Instruction,
                            names::Dict{_LLVMRef, Symbol}, counter::Ref{Int}, ops,
                            dest::Symbol, ptr_cells::Bool=false)
    # Predicate 1: addrspace 0 (accept both `memset.p0.` and `memset.inline.p0.`).
    is_p0 = startswith(cname, "llvm.memset.p0.") ||
            startswith(cname, "llvm.memset.inline.p0.")
    is_p0 || _ir_error(inst,
        "$(cname): memset with non-default pointer address space is not " *
        "supported. Bennett.jl's wire model is single-address-space; " *
        "cross-space writes need explicit lowering. Tracked in " *
        "Bennett-8bys. (Bennett-9nwt Phase 2 — addrspace 0 only)")

    n_ops = length(ops)
    n_ops >= 5 || _ir_error(inst,
        "$(cname): malformed memset call (expected 4 args + callee, got " *
        "$(n_ops - 1) args). (Bennett-9nwt Phase 2)")

    dst_v = ops[1]
    c_v   = ops[2]
    n_v   = ops[3]
    vol_v = ops[4]

    # Predicate 3: isvolatile must be a ConstantInt (malformed-IR guard).
    # The volatile *value* check is relocated below, after the c==0/N==0
    # drop (Bennett-8su4) — but this constant-shape guard must stay early:
    # it fails loud on malformed IR (§1) and must dominate the relocated
    # `_const_int_as_int(vol_v)` call.
    vol_v isa LLVM.ConstantInt || _ir_error(inst,
        "$(cname): isvolatile arg is not an i1 immarg constant " *
        "(value=$(string(vol_v))). LangRef requires an immarg here; " *
        "malformed IR. (Bennett-9nwt Phase 2)")

    # Predicate 4: fill byte must be a ConstantInt.
    c_v isa LLVM.ConstantInt || _ir_error(inst,
        "$(cname): memset with non-constant fill byte is not supported. " *
        "Variable c needs runtime broadcasting that the byte-granular " *
        "IRStore-of-ConstOperand path cannot express. Tracked in " *
        "Bennett-8bys. (Bennett-9nwt Phase 2 — const-c only)")

    # Predicate 5: byte count must be a ConstantInt.
    if !(n_v isa LLVM.ConstantInt)
        # Bennett-8bys / CW-D (ADR 0017): under ptr_cells, a VARIABLE-size memset
        # routes to IRCall(:memset,[dst,byte,nbytes]) → BVM's reversible
        # IntrinsicMemset (ingest_call.jl :memset→IntrinsicMemset, :memset ∈
        # _HEAP_DISPATCH; its L2 delta reverses fresh-absent OR stale, so no
        # freshness proof is needed here). The byte is passed RAW — BVM's
        # IntrinsicMemset.forward does its own cell-broadcast; pre-broadcasting
        # here would double-broadcast. A VOLATILE variable-N memset still fails
        # loud (Rule 1). Const-N keeps the unroll; ptr_cells=false keeps the
        # reject — both byte-identical. `vol_v` is proven ConstantInt at
        # predicate 3 above, so `_const_int_as_int(vol_v)` is safe.
        if ptr_cells && _const_int_as_int(vol_v) == 0
            dst_op = _operand(dst_v, names; ptr_cells=true)   # .data ptr → Int64 cell
            dst_op isa SSAOperand || _ir_error(inst,
                "$(cname): variable-size memset dst is not an SSA pointer cell " *
                "(got $(dst_op)); BVM IntrinsicMemset needs an SSA dst. (Bennett-8bys)")
            return IRCall(dest, :memset,
                IROperand[dst_op, _operand(c_v, names), _operand(n_v, names)],
                Int[64, 8, 64], 64)
        end
        _ir_error(inst,
            "$(cname): memset with non-constant byte count is not supported. " *
            "Variable-size memset requires runtime-bounded loop unrolling, " *
            "same gap as variable-size memcpy. Tracked in Bennett-8bys. " *
            "(Bennett-9nwt Phase 2 — const-N only)")
    end
    N = _const_int_as_int(n_v)
    N >= 0 || _ir_error(inst,
        "$(cname): negative byte count $N (corrupt IR; LLVM treats the " *
        "size argument as unsigned i64 but the C API returns Int64). " *
        "(Bennett-9nwt Phase 2)")

    # Predicate 7: N == 0 is a legal no-op regardless of c, dst, freshness.
    N == 0 && return IRInst[]

    # Predicate 8: c == 0 → case A. Silent drop, preserves pre-9nwt benign
    # behaviour. Intentionally NO alloca / freshness check here —
    # tightening risks regressing unaudited Julia frontend output, and the
    # benign-list it replaces also did no such check. The c=0 non-fresh
    # silent miscompile is an acknowledged hazard tracked in
    # Bennett-8bys-uncompute.
    c_int = _const_int_as_int(c_v) & 0xFF
    c_int == 0 && return IRInst[]

    # Predicate 8b: volatile value check (relocated here from before
    # predicate 4 — Bennett-8su4). A c==0 or N==0 memset is already
    # dropped above (predicates 7/8) and emits zero IRInsts regardless of
    # volatility, so volatility is moot for it — this lets Julia's
    # volatile c=0 GC-frame zero-init memset through. Control only
    # reaches here when c!=0, so volatile c!=0 still fails loud.
    _const_int_as_int(vol_v) == 0 || _ir_error(inst,
        "$(cname): volatile memset is not supported. Bennett.jl's " *
        "reversible model has no observable side-effect ordering for " *
        "memory; volatile semantics cannot be honoured. Recompile " *
        "without the volatile attribute, or wait on Bennett-8bys " *
        "(catch-all). (Bennett-9nwt Phase 2)")

    # ---- c != 0 path: requires alloca-i8-backed fresh dst ----

    # Predicate 9: dst SSA must be in the names table.
    haskey(names, dst_v.ref) || _ir_error(inst,
        "$(cname): memset dst pointer is not a named SSA value. " *
        "(Bennett-9nwt Phase 2)")

    # Predicate 10: globals out of scope.
    if LLVM.API.LLVMIsAGlobalVariable(dst_v.ref) != C_NULL
        _ir_error(inst,
            "$(cname): memset of a global-variable destination is not " *
            "yet supported. Constant-target memset against a global " *
            "would mutate read-only data. Tracked in Bennett-8bys " *
            "(catch-all, sub-case: \"Global-pointer memset\"). " *
            "(Bennett-9nwt Phase 2 — alloca-backed dst only)")
    end

    # Predicate 11: dst must trace to an alloca (direct or const-offset GEP).
    dst_root = _alloca_root_ref(dst_v)
    dst_root === nothing && _ir_error(inst,
        "$(cname): memset dst operand is not alloca-backed (or " *
        "alloca-backed via a const-offset GEP). Bennett's pointer- " *
        "provenance model only covers alloca and GEP-of-alloca; pointer " *
        "phi/select/parameter sources fan out to multiple origins which " *
        "Bennett-9nwt does not yet handle. Tracked in Bennett-8bys. " *
        "(Bennett-9nwt Phase 2)")

    # Predicate 12: alloca element type must be integer.
    # Bennett-ixiz (2026-05-16) lifted the prior `dst_ew == 8` gate;
    # arbitrary integer element widths are now accepted, with the fill
    # byte c broadcast across the element width (see _broadcast_byte_to_width).
    dst_ew = _alloca_elem_width_bits(dst_root)
    dst_ew == 0 && _ir_error(inst,
        "$(cname): memset dst alloca has non-integer element type " *
        "(struct, ptr, nested-array, or non-integer ArrayType inner). " *
        "Bennett's wire model only supports flat integer-typed allocas. " *
        "Tracked in Bennett-8bys. (Bennett-9nwt / Bennett-ixiz)")

    # Predicate 12b (Bennett-ixiz): N must be a whole multiple of element-
    # size bytes. Byte-granular tail set (setting partial element bytes)
    # is out-of-scope.
    rem(N * 8, dst_ew) == 0 || _ir_error(inst,
        "$(cname): memset N=$N bytes is not a multiple of element size " *
        "$(div(dst_ew, 8)) bytes — byte-granular tail set is out-of-scope " *
        "for Bennett-ixiz. Tracked in Bennett-8bys.")

    # Predicate 13: freshness (intra-block sweep). Non-fresh dst would
    # XOR-overlay c onto existing data instead of cleanly setting it,
    # producing wrong results that `verify_reversibility` doesn't catch.
    _alloca_is_fresh(dst_root, inst) || _ir_error(inst,
        "$(cname): memset dst alloca has prior IR-visible writes within " *
        "this basic block (non-fresh dst). Reversibility forbids " *
        "destructive overwrite without first uncomputing the existing " *
        "slot bits via CNOT-uncompute. Tracked in " *
        "Bennett-8bys-uncompute. (Bennett-9nwt Phase 2 — fresh-dst only)")

    # Case C expansion (Bennett-ixiz): K element-granular IRPtrOffset+IRStore
    # pairs at width = dst_ew, where K = N / ew_bytes. The byte fill c is
    # broadcast across the full element width (e.g. c=0xAB → 0xABABABABABABABAB
    # for ew=64) via _broadcast_byte_to_width.
    ew_bytes = div(dst_ew, 8)
    K = div(N, ew_bytes)
    c_broadcast = _broadcast_byte_to_width(c_int, dst_ew)
    dst_op = ssa(names[dst_v.ref])
    out = IRInst[]
    sizehint!(out, 2 * K)
    for k in 0:(K - 1)
        dst_off = _auto_name(counter)
        push!(out, IRPtrOffset(dst_off, dst_op, k * ew_bytes, dst_ew))
        push!(out, IRStore(ssa(dst_off), iconst(c_broadcast), dst_ew))
    end
    return out
end

# Bennett-tzrs / U41 (first-cut, 2026-04-27): the LLVM-intrinsic prefix
# dispatch was lifted out of `_convert_instruction`'s 836-line body into
# this helper. Order of `if startswith(cname, "...")` branches is LOAD-
# BEARING — `llvm.minnum` / `llvm.minimum` and `llvm.maxnum` / `llvm.maximum`
# share handlers via prefix-match, and the floor/ceil/trunc/rint
# branch is INTENTIONALLY a no-op (it lets the registered-callee path in
# `_convert_instruction` pick up `soft_floor` / `soft_ceil` / etc. via
# the SoftFloat dispatch). `llvm.round.` and `llvm.roundeven.` have
# explicit dispatch arms (Bennett-mq6f) because they semantically
# diverge — `llvm.round` is round-half-AWAY (`soft_round_away`) while
# `llvm.roundeven` is banker's (`soft_round`). Returns `nothing` if no intrinsic matched —
# the call site then proceeds to the registered-callee lookup and the
# benign-allowlist guard. Per CLAUDE.md §2 this is part of the 3+1-mandated
# tzrs refactor (proposers: A and B; orchestrator: tobias 2026-04-27).
function _handle_intrinsic(cname::AbstractString, inst::LLVM.Instruction,
                           names::Dict{_LLVMRef, Symbol}, counter::Ref{Int},
                           dest::Symbol, ops,
                           globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}=
                               Dict{Symbol, Tuple{Vector{UInt64}, Int}}();
                           synth_ptr_provenance::Set{Tuple{Symbol, Int, Int}}=
                               Set{Tuple{Symbol, Int, Int}}(),
                           synth_ptr_allocas::Set{_LLVMRef}=Set{_LLVMRef}(),
                           ptr_cells::Bool=false)
    if startswith(cname, "llvm.umax.")
        cmp_dest = _auto_name(counter)
        w = _iwidth(ops[1])
        return [
            IRICmp(cmp_dest, :uge, _operand(ops[1], names), _operand(ops[2], names), w),
            IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
        ]
    end
    if startswith(cname, "llvm.umin.")
        cmp_dest = _auto_name(counter)
        w = _iwidth(ops[1])
        return [
            IRICmp(cmp_dest, :ule, _operand(ops[1], names), _operand(ops[2], names), w),
            IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
        ]
    end
    if startswith(cname, "llvm.smax.")
        cmp_dest = _auto_name(counter)
        w = _iwidth(ops[1])
        return [
            IRICmp(cmp_dest, :sge, _operand(ops[1], names), _operand(ops[2], names), w),
            IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
        ]
    end
    if startswith(cname, "llvm.smin.")
        cmp_dest = _auto_name(counter)
        w = _iwidth(ops[1])
        return [
            IRICmp(cmp_dest, :sle, _operand(ops[1], names), _operand(ops[2], names), w),
            IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
        ]
    end
    # llvm.abs.iN(x, is_int_min_poison) = x >= 0 ? x : 0 - x
    if startswith(cname, "llvm.abs.")
        w = _iwidth(ops[1])
        x_op = _operand(ops[1], names)
        neg_dest = _auto_name(counter)
        cmp_dest = _auto_name(counter)
        return [
            IRBinOp(neg_dest, :sub, iconst(0), x_op, w),
            IRICmp(cmp_dest, :sge, x_op, iconst(0), w),
            IRSelect(dest, ssa(cmp_dest), x_op, ssa(neg_dest), w),
        ]
    end
    # llvm.ctpop.iN(x) = popcount(x)
    # Expand: sum of individual bits via cascaded add
    if startswith(cname, "llvm.ctpop.")
        w = _iwidth(ops[1])
        x_op = _operand(ops[1], names)
        result = IRInst[]
        # Extract each bit: bit_i = (x >> i) & 1
        # Then sum them up: result = bit_0 + bit_1 + ... + bit_{W-1}
        prev = _auto_name(counter)
        push!(result, IRBinOp(prev, :and, x_op, iconst(1), w))
        for i in 1:(w - 1)
            shifted = _auto_name(counter)
            bit = _auto_name(counter)
            acc = _auto_name(counter)
            push!(result, IRBinOp(shifted, :lshr, x_op, iconst(i), w))
            push!(result, IRBinOp(bit, :and, ssa(shifted), iconst(1), w))
            push!(result, IRBinOp(acc, :add, ssa(prev), ssa(bit), w))
            prev = acc
        end
        # Rename last accumulator to dest
        push!(result, IRBinOp(dest, :add, ssa(prev), iconst(0), w))
        return result
    end
    # llvm.ctlz.iN(x, is_zero_poison) = count leading zeros
    # Expand: cascade LSB→MSB so highest set bit wins (overwrites last)
    if startswith(cname, "llvm.ctlz.")
        w = _iwidth(ops[1])
        x_op = _operand(ops[1], names)
        result = IRInst[]
        prev = _auto_name(counter)
        push!(result, IRBinOp(prev, :add, iconst(w), iconst(0), w))  # default: W (all zeros)
        for i in 0:(w - 1)  # LSB to MSB; last match = highest bit = correct clz
            shifted = _auto_name(counter)
            bit = _auto_name(counter)
            is_set = _auto_name(counter)
            new_val = _auto_name(counter)
            push!(result, IRBinOp(shifted, :lshr, x_op, iconst(i), w))
            push!(result, IRBinOp(bit, :and, ssa(shifted), iconst(1), w))
            push!(result, IRICmp(is_set, :ne, ssa(bit), iconst(0), w))
            push!(result, IRSelect(new_val, ssa(is_set), iconst(w - 1 - i), ssa(prev), w))
            prev = new_val
        end
        push!(result, IRBinOp(dest, :add, ssa(prev), iconst(0), w))
        return result
    end
    # llvm.cttz.iN(x, is_zero_poison) = count trailing zeros
    # Cascade MSB→LSB so lowest set bit wins (overwrites last)
    if startswith(cname, "llvm.cttz.")
        w = _iwidth(ops[1])
        x_op = _operand(ops[1], names)
        result = IRInst[]
        prev = _auto_name(counter)
        push!(result, IRBinOp(prev, :add, iconst(w), iconst(0), w))
        for i in (w - 1):-1:0  # MSB to LSB; last match = lowest bit = correct ctz
            shifted = _auto_name(counter)
            bit = _auto_name(counter)
            is_set = _auto_name(counter)
            new_val = _auto_name(counter)
            push!(result, IRBinOp(shifted, :lshr, x_op, iconst(i), w))
            push!(result, IRBinOp(bit, :and, ssa(shifted), iconst(1), w))
            push!(result, IRICmp(is_set, :ne, ssa(bit), iconst(0), w))
            push!(result, IRSelect(new_val, ssa(is_set), iconst(i), ssa(prev), w))
            prev = new_val
        end
        push!(result, IRBinOp(dest, :add, ssa(prev), iconst(0), w))
        return result
    end
    # llvm.bitreverse.iN(x) = reverse bit order
    # Expand: for each bit, shift to mirrored position and OR together
    if startswith(cname, "llvm.bitreverse.")
        w = _iwidth(ops[1])
        x_op = _operand(ops[1], names)
        result = IRInst[]
        # bit_i → position (W-1-i): shift right by i, mask, shift left by (W-1-i)
        prev = _auto_name(counter)
        # First bit
        shifted0 = _auto_name(counter)
        push!(result, IRBinOp(shifted0, :lshr, x_op, iconst(0), w))
        push!(result, IRBinOp(prev, :and, ssa(shifted0), iconst(1), w))
        shl0 = _auto_name(counter)
        push!(result, IRBinOp(shl0, :shl, ssa(prev), iconst(w - 1), w))
        prev = shl0
        for i in 1:(w - 1)
            shifted = _auto_name(counter)
            bit = _auto_name(counter)
            placed = _auto_name(counter)
            acc = _auto_name(counter)
            push!(result, IRBinOp(shifted, :lshr, x_op, iconst(i), w))
            push!(result, IRBinOp(bit, :and, ssa(shifted), iconst(1), w))
            push!(result, IRBinOp(placed, :shl, ssa(bit), iconst(w - 1 - i), w))
            push!(result, IRBinOp(acc, :or, ssa(prev), ssa(placed), w))
            prev = acc
        end
        push!(result, IRBinOp(dest, :add, ssa(prev), iconst(0), w))
        return result
    end
    # llvm.bswap.iN(x) = reverse byte order (N must be multiple of 16)
    if startswith(cname, "llvm.bswap.")
        w = _iwidth(ops[1])
        x_op = _operand(ops[1], names)
        n_bytes = w ÷ 8
        result = IRInst[]
        # Extract each byte, shift to swapped position, OR together
        prev = _auto_name(counter)
        byte0 = _auto_name(counter)
        push!(result, IRBinOp(byte0, :and, x_op, iconst(255), w))
        push!(result, IRBinOp(prev, :shl, ssa(byte0), iconst((n_bytes - 1) * 8), w))
        for b in 1:(n_bytes - 1)
            shifted = _auto_name(counter)
            byte_val = _auto_name(counter)
            placed = _auto_name(counter)
            acc = _auto_name(counter)
            push!(result, IRBinOp(shifted, :lshr, x_op, iconst(b * 8), w))
            push!(result, IRBinOp(byte_val, :and, ssa(shifted), iconst(255), w))
            push!(result, IRBinOp(placed, :shl, ssa(byte_val), iconst((n_bytes - 1 - b) * 8), w))
            push!(result, IRBinOp(acc, :or, ssa(prev), ssa(placed), w))
            prev = acc
        end
        push!(result, IRBinOp(dest, :add, ssa(prev), iconst(0), w))
        return result
    end
    # llvm.fshl.i64(a, b, shift) = (a << shift) | (b >> (64 - shift))
    if startswith(cname, "llvm.fshl.")
        w = _iwidth(ops[1])
        a_op = _operand(ops[1], names)
        b_op = _operand(ops[2], names)
        sh_op = _operand(ops[3], names)
        shl_dest = _auto_name(counter)
        lshr_dest = _auto_name(counter)
        if sh_op isa ConstOperand
            # Constant-fold: w - const is const (no runtime sub needed)
            return [
                IRBinOp(shl_dest, :shl, a_op, sh_op, w),
                IRBinOp(lshr_dest, :lshr, b_op, iconst(w - sh_op.value), w),
                IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
            ]
        else
            rsh_amount = _auto_name(counter)
            return [
                IRBinOp(shl_dest, :shl, a_op, sh_op, w),
                IRBinOp(rsh_amount, :sub, iconst(w), sh_op, w),
                IRBinOp(lshr_dest, :lshr, b_op, ssa(rsh_amount), w),
                IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
            ]
        end
    end
    # llvm.fshr.i64(a, b, shift) = (a << (64 - shift)) | (b >> shift)
    if startswith(cname, "llvm.fshr.")
        w = _iwidth(ops[1])
        a_op = _operand(ops[1], names)
        b_op = _operand(ops[2], names)
        sh_op = _operand(ops[3], names)
        shl_dest = _auto_name(counter)
        lshr_dest = _auto_name(counter)
        if sh_op isa ConstOperand
            # Constant-fold: w - const is const
            return [
                IRBinOp(shl_dest, :shl, a_op, iconst(w - sh_op.value), w),
                IRBinOp(lshr_dest, :lshr, b_op, sh_op, w),
                IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
            ]
        else
            shl_amount = _auto_name(counter)
            return [
                IRBinOp(shl_amount, :sub, iconst(w), sh_op, w),
                IRBinOp(shl_dest, :shl, a_op, ssa(shl_amount), w),
                IRBinOp(lshr_dest, :lshr, b_op, sh_op, w),
                IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
            ]
        end
    end
    # llvm.fabs: clear sign bit (AND with ~sign_bit)
    if startswith(cname, "llvm.fabs.")
        w = _iwidth(ops[1])
        mask = w == 64 ? typemax(Int64) : Int((1 << (w - 1)) - 1)
        return IRBinOp(dest, :and, _operand(ops[1], names), iconst(mask), w)
    end
    # llvm.copysign: (x AND ~sign_bit) OR (y AND sign_bit)
    if startswith(cname, "llvm.copysign.")
        w = _iwidth(ops[1])
        mag_mask = w == 64 ? typemax(Int64) : Int((1 << (w - 1)) - 1)
        sign_bit = w == 64 ? typemin(Int64) : Int(1 << (w - 1))
        x_op = _operand(ops[1], names)
        y_op = _operand(ops[2], names)
        mag = _auto_name(counter)
        sgn = _auto_name(counter)
        return [
            IRBinOp(mag, :and, x_op, iconst(mag_mask), w),
            IRBinOp(sgn, :and, y_op, iconst(sign_bit), w),
            IRBinOp(dest, :or, ssa(mag), ssa(sgn), w),
        ]
    end
    # Bennett-mq6f: `llvm.roundeven.f64` is IEEE 754 roundToIntegralTiesToEven
    # (banker's rounding) — bit-exactly equivalent to our `soft_round` (which
    # is also banker's, matching `Base.round(::Float64)` per Bennett-2hhx).
    # Native dispatch closes the kh6n future-work stub.
    #
    # Bennett-kh6n's earlier explicit reject (since removed) incorrectly
    # claimed `soft_round` was round-half-AWAY; in fact `soft_round` IS
    # banker's, and the silent miscompile direction is reversed — see the
    # `llvm.round.` arm below for the actual round-half-AWAY dispatch.
    if startswith(cname, "llvm.roundeven.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.roundeven: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-mq6f)")
        return IRCall(dest, soft_round, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-mq6f: `llvm.round.f64` is IEEE 754 roundToIntegralTiesToAway
    # (round-half-AWAY-from-zero) per LLVM langref — DISTINCT from
    # `llvm.roundeven.f64` (banker's). Pre-Bennett-mq6f this arm fell
    # through to the no-op `floor/ceil/trunc/rint/round` block below and
    # then hit the callee-registry path which (correctly) dispatches
    # `soft_round` for the SoftFloat-typed `Base.round` — but `soft_round`
    # is banker's, so raw `.ll` ingest of `llvm.round.f64` silently
    # miscompiled at every `±N.5` tie. Native dispatch to the new
    # `soft_round_away` primitive closes the gap.
    if startswith(cname, "llvm.round.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.round: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-mq6f)")
        return IRCall(dest, soft_round_away, [_operand(ops[1], names)], [w], w)
    end
    # llvm.floor / llvm.ceil / llvm.trunc / llvm.rint
    # Intentionally NO return: the registered-callee path in
    # `_convert_instruction` picks these up via SoftFloat dispatch
    # (`soft_floor` / `soft_ceil` / `soft_trunc` are registered callees).
    # Falling through to the next `if` keeps the original semantics.
    # Bennett-mq6f: `llvm.round.` and `llvm.roundeven.` are no longer
    # part of this no-op arm — both have explicit dispatch above (with
    # different rounding modes). `llvm.rint.` defaults to round-to-nearest-
    # ties-to-even per IEEE 754; the callee registry serves that via
    # `soft_round` (banker's).
    if startswith(cname, "llvm.floor.") || startswith(cname, "llvm.ceil.") ||
       startswith(cname, "llvm.trunc.") || startswith(cname, "llvm.rint.")
        # No-op: handled by callee registry
    end
    # Bennett-p19b: native dispatch for IEEE 754-2019 minimumNumber /
    # maximumNumber (LLVM 19+ `llvm.minimumnum.*` / `llvm.maximumnum.*`).
    # Semantically NaN-absorbing with the ±0 tie-break SPECIFIED
    # (-0.0 < +0.0 in min, +0.0 > -0.0 in max). Our `soft_fmin` /
    # `soft_fmax` already chose the specified ±0 behavior (matches
    # `Base.min` / `Base.max`), so `soft_minimumnum` / `soft_maximumnum`
    # are aliased thin wrappers over them — see src/softfloat/fmin.jl.
    # Both arms appear BEFORE the shorter `llvm.minimum.` / `llvm.maximum.`
    # arms below (defense in depth: trailing-`.` already prevents the
    # shorter prefix from matching `*num`, but longest-first ordering
    # is robust to future prefix-discipline drift). Closes the third
    # and final Bennett-kh6n future-work stub (after k2w6 + mq6f).
    if startswith(cname, "llvm.minimumnum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.minimumnum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-p19b)")
        return IRCall(dest, soft_minimumnum,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    if startswith(cname, "llvm.maximumnum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.maximumnum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-p19b)")
        return IRCall(dest, soft_maximumnum,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    # llvm.minnum / llvm.maxnum / llvm.minimum / llvm.maximum
    # Trailing-`.` discipline (Bennett-kh6n): without it, `llvm.minimum`
    # silently swallows `llvm.minimumnum.*` and `llvm.maximum` swallows
    # `llvm.maximumnum.*` (handled by the explicit Bennett-p19b arms above).
    #
    # Bennett-k2w6: native dispatch for all four float min/max variants.
    # Two semantic pairs:
    #   - llvm.minnum  / llvm.maxnum   ≡ IEEE 754 minNum/maxNum, NaN-absorbing.
    #   - llvm.minimum / llvm.maximum  ≡ IEEE 754-2008 minimum/maximum,
    #                                    NaN-propagating (matches Julia
    #                                    Base.min/max bit-exactly).
    # f32 rejected per CLAUDE.md §13 (Bennett-3rph). The original
    # IRICmp(:slt)/(:sgt) integer-compare path that pre-Bennett-kh6n
    # silently dispatched float operands is removed — it was always wrong
    # for f64 (mishandles +0/-0 and NaN), and llvm.minnum/minimum/maxnum/
    # maximum are float-only intrinsics per LLVM langref so the integer
    # path was pure dead code.
    if startswith(cname, "llvm.minnum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.minnum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-k2w6)")
        return IRCall(dest, soft_fmin,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    if startswith(cname, "llvm.maxnum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.maxnum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-k2w6)")
        return IRCall(dest, soft_fmax,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    if startswith(cname, "llvm.minimum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.minimum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-k2w6)")
        return IRCall(dest, soft_fminimum,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    if startswith(cname, "llvm.maximum.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.maximum: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-k2w6)")
        return IRCall(dest, soft_fmaximum,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    # Bennett-1pb: direct dispatch for transcendental intrinsics. The Julia
    # frontend normally routes these through SoftFloat dispatch
    # (`Base.sqrt(::SoftFloat) = SoftFloat(soft_fsqrt(x.bits))`), so the IR
    # call site is `@j_soft_fsqrt_NNN` rather than `@llvm.sqrt.f64`. But IR
    # can still arrive at the extractor with raw `llvm.sqrt.f64` etc. when
    # the user calls `Core.Intrinsics.sqrt_llvm` directly, uses `@fastmath`
    # on a raw Float64, or — looking ahead to Bennett-xkv — feeds in
    # `.ll`/`.bc` from C/Rust where no SoftFloat wrapper exists. The bit
    # pattern of the f64 operand is treated as a 64-bit wire (LLVM bitcasts
    # adjacent to the call site already turn raw double SSA into integer
    # wires). Width-32/16 forms are rejected per CLAUDE.md §13 (Float32 not
    # bit-exact; native f32 paths tracked in Bennett-e283).
    #
    # `llvm.exp2.*` is checked before `llvm.exp.*` because both share the
    # `llvm.exp` prefix; the order is load-bearing.
    if startswith(cname, "llvm.sqrt.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.sqrt: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-1pb)")
        return IRCall(dest, soft_fsqrt, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.exp2.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.exp2: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-1pb)")
        return IRCall(dest, soft_exp2, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-h6f: fused multiply-add. `soft_fma` is a bit-exact IEEE 754
    # binary64 FMA (single rounding via 106-bit intermediate product;
    # Bennett-0xx3, 2026-04-16). `llvm.fmuladd` is allowed by LangRef to
    # be split into fmul+fadd by the lowerer, but Bennett deliberately
    # routes both `fma` and `fmuladd` to `soft_fma` — the alternative
    # would mean fmuladd produces a different last-ulp answer than fma
    # on the same inputs, which is a class of "silent disagreement" bug
    # CLAUDE.md §1 (fail loud) + §13 (bit-exact f64) explicitly avoid.
    if startswith(cname, "llvm.fma.") || startswith(cname, "llvm.fmuladd.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.fma/fmuladd: only f64 supported (got width=$w); native " *
            "f32/f16 paths are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-h6f)")
        return IRCall(dest, soft_fma,
                      [_operand(ops[1], names),
                       _operand(ops[2], names),
                       _operand(ops[3], names)],
                      [w, w, w], w)
    end
    # Trailing `.` per Bennett-7goc / 0ulc discipline: prevents
    # `startswith("llvm.exp")` from silently swallowing
    # `llvm.expm1.f64` (which is dispatched in a separate arm
    # below at the C2 transcendental section per Bennett-o7cy).
    if startswith(cname, "llvm.exp.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.exp: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-1pb)")
        return IRCall(dest, soft_exp, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-582: direct dispatch for the LLVM logarithm intrinsic family.
    # Like the exp dispatch above, the Julia frontend normally routes log
    # through SoftFloat (`Base.log(::SoftFloat) = SoftFloat(soft_log_julia(x.bits))`
    # — when wired). Raw `llvm.log.f64` arrives via @fastmath, Core.Intrinsics,
    # or .ll/.bc ingest (Bennett-xkv multi-language path).
    #
    # Order is load-bearing: `llvm.log10.*` and `llvm.log2.*` must be checked
    # BEFORE `llvm.log.*` because `startswith("llvm.log")` matches all three.
    # f64 only — f32 rejected per CLAUDE.md §13 (Bennett-3rph / U137).
    #
    # Trailing `.` discipline (Bennett-7goc): each prefix has a trailing
    # `.` so it doesn't accidentally swallow another intrinsic with a
    # longer name. Pre-Bennett-0ulc the `llvm.log` arm was untightened
    # and silently swallowed `llvm.log1p.f64` — same class of bug as
    # the pre-7goc `llvm.atan` swallowing `llvm.atan2.f64`. Tightened
    # all three log-family prefixes here.
    if startswith(cname, "llvm.log10.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log10: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-582)")
        return IRCall(dest, soft_log10, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.log2.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log2: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-582)")
        return IRCall(dest, soft_log2, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-0ulc: `llvm.log1p.f64` → `soft_log1p`. MUST come before
    # the `llvm.log.` arm because position-9 of `llvm.log1p.f64` is `1`,
    # not `.`. With the trailing-`.` discipline applied to `llvm.log.`,
    # ordering is no longer strictly required — but kept for clarity
    # and to mirror the trig family's discipline.
    if startswith(cname, "llvm.log1p.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log1p: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-0ulc)")
        return IRCall(dest, soft_log1p, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.log.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-582)")
        return IRCall(dest, soft_log, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-emv: direct dispatch for llvm.pow / llvm.powi.
    # `llvm.powi.f64.i32` has a different signature than llvm.pow — base is
    # f64, exponent is i32 — so it routes to soft_powi (binary squaring),
    # not soft_pow. Order is load-bearing again: `llvm.powi.*` checked
    # before `llvm.pow.*` because both share the `llvm.pow` prefix.
    if startswith(cname, "llvm.powi.")
        w_base = _iwidth(ops[1])
        w_exp  = _iwidth(ops[2])
        w_base == 64 || _ir_error(inst,
            "llvm.powi: only f64 base supported (got width=$w_base); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-emv)")
        w_exp == 32 || _ir_error(inst,
            "llvm.powi: only i32 exponent supported (got width=$w_exp); " *
            "Bennett supports the standard `llvm.powi.f64.i32` form. " *
            "(Bennett-emv)")
        return IRCall(dest, soft_powi,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w_base, w_exp], w_base)
    end
    if startswith(cname, "llvm.pow.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.pow: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-emv)")
        return IRCall(dest, soft_pow,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    # Bennett-3mo: direct dispatch for the LLVM trigonometric intrinsics.
    # `soft_sin` / `soft_cos` are full-Payne-Hanek ports of musl `sin.c` /
    # `cos.c` / `__rem_pio2_large.c`, ≤2 ULP vs `Base.sin` / `Base.cos`
    # across the full Float64 input range. f32 rejected per §13.
    # Trailing `.` in the prefix is load-bearing: it prevents
    # `startswith("llvm.sin")` from matching `"llvm.sinh.f64"` (which we
    # don't support yet) and accidentally dispatching to soft_sin.
    # Same fix applied to cos/tan/atan/asin/acos below — see Bennett-7goc
    # for the silent-miscompile root cause (`startswith("llvm.atan")`
    # matched `"llvm.atan2.f64"` and dropped the second operand).
    if startswith(cname, "llvm.sin.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.sin: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-3mo)")
        return IRCall(dest, soft_sin, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-hao Phase 1 (Bennett-37mt): const-size memcpy between two
    # distinct alloca-i8-backed pointer ranges lowers to byte-granular
    # IRPtrOffset+IRPtrOffset+IRLoad+IRStore quads. Out-of-scope shapes
    # fall through to a precise fail-loud naming Bennett-8bys (catch-all
    # for byte-granularity / variable-size / overlap / wider-elem-w
    # allocas) or Bennett-haod (deferred sub-bead for global-variable
    # source pointers). memmove fails loud on the CIRCUIT path (overlap is
    # unreachable in the reversible model regardless of pointer
    # disjointness); under the closed-world `ptr_cells` gate it routes to
    # `IRCall(:memmove)` instead — see the Bennett-vau9 arm below. The
    # Phase 0 (Bennett-lqif) blanket fail-loud is superseded by this arm.
    #
    # Why byte-granular chunks (rather than the bead's "(N/8) at 64-bit
    # granularity" wording): the existing `lower_ptr_offset!`
    # (src/lowering/aggregate.jl:227) only propagates ptr_provenance for
    # `ew == 8`, and `_lower_store_via_shadow!` requires
    # `inst.width == elem_w`. The single-Phase-1 chunk shape that lands
    # cleanly through the existing memory.jl pipeline is therefore
    # `alloca i8` + width=8 IRLoad/IRStore. Wider-element allocas and
    # 64-bit chunks are deferred to 8bys (which is also where memory.jl
    # itself can grow multi-byte spans). With byte-granular chunks the
    # bead's "N is multiple of 8 bytes" wording becomes moot — any
    # positive N works.
    if startswith(cname, "llvm.memmove.")
        # Bennett-vau9 / CW-D (ADR 0017): under the closed-world `ptr_cells`
        # gate a memmove routes to
        #   IRCall(dest, :memmove, [dst_cell, src_cell, nbytes], [64,64,64], 64)
        # → BennettVM's `IntrinsicMemmove` (`:memmove` ∈ `_HEAP_DISPATCH`,
        # ingest_call.jl; forward snapshots the whole src range BEFORE writing
        # dest, so OVERLAP is safe by construction, and the L2 dest-range delta
        # reverses it — the clobbered src cells are a subset of the dest range,
        # so no src delta is needed). Unblocks `_growend!`, whose grow-copy
        # moves the old elements into the newly allocated buffer.
        #
        # This mirrors the ratified Bennett-8bys variable-size-memset D5b
        # void-call shape (predicate 5 of `_handle_memset_arm`), with two
        # deliberate differences:
        #
        #   * TWO SSA pointer operands (dst AND src), both required to resolve
        #     to `SSAOperand` cells — `IntrinsicMemmove` takes two `Symbol`
        #     pointer names.
        #   * NO legacy const-N unroll to preserve: memmove has ALWAYS failed
        #     loud, so the WHOLE arm is gated on `ptr_cells` and a CONST byte
        #     count routes through the same `IRCall` (BVM resolves an `Int64`
        #     `nbytes_operand` just as happily as a `Symbol`). Consequence:
        #     under `ptr_cells=false` the legacy reject stands for every shape,
        #     byte-identically except for the added Bennett-vau9 clause naming
        #     the gate.
        #
        # `n_v` is passed through `_operand` WITHOUT `ptr_cells=true`: it is a
        # byte COUNT, not a pointer, and BVM's `_cell_count` divides it by 8.
        #
        # DOWNSTREAM BOUNDARY (not this arm's job, but know it exists): BVM's
        # `_enforce_julia_heap_tier!` fails loud on an `IntrinsicMemmove` in a
        # JULIA-tier program (`gc_alloc_obj` / `jl_alloc_genericmemory_*`
        # allocs, byte-granular cells) because the `÷8` span would copy an
        # eighth of a byte range — bead `bennettvm-rxgy` tracks the byte-exact
        # `IntrinsicMemmoveBytes` (sibling of the existing
        # `IntrinsicMemsetBytes`). Routing here is still right: extraction
        # must not wall on a shape the VM models, and the tier mismatch
        # arrives LOUDLY at `lower_vm`, not as a silent short copy.
        if ptr_cells
            # Predicate 1: addrspace 0 on BOTH pointers (encoded in the
            # intrinsic name — mirrors the memcpy arm's prefix check).
            startswith(cname, "llvm.memmove.p0.p0.") || _ir_error(inst,
                "$(cname): memmove with a non-default pointer address space " *
                "is not supported. Bennett.jl's cell model is " *
                "single-address-space; cross-space moves need explicit " *
                "lowering. (Bennett-vau9 — addrspace 0 only)")

            n_ops_mm = length(ops)
            n_ops_mm >= 5 || _ir_error(inst,
                "$(cname): malformed memmove call (expected 4 args + callee, " *
                "got $(n_ops_mm - 1) args). (Bennett-vau9)")

            dst_v = ops[1]
            src_v = ops[2]
            n_v   = ops[3]
            vol_v = ops[4]

            # Predicate 2: isvolatile must be a ConstantInt (malformed-IR
            # guard — LangRef requires an immarg here) with value 0.
            vol_v isa LLVM.ConstantInt || _ir_error(inst,
                "$(cname): isvolatile arg is not an i1 immarg constant " *
                "(value=$(string(vol_v))). LangRef requires an immarg here; " *
                "malformed IR. (Bennett-vau9)")
            _const_int_as_int(vol_v) == 0 || _ir_error(inst,
                "$(cname): volatile memmove is not supported. Bennett.jl's " *
                "reversible model has no observable side-effect ordering for " *
                "memory; volatile semantics cannot be honoured. Recompile " *
                "without the volatile attribute. (Bennett-vau9 — Rule 1)")

            # Predicate 3: BOTH pointers must resolve to SSA cells.
            dst_op = _operand(dst_v, names; ptr_cells=true)
            dst_op isa SSAOperand || _ir_error(inst,
                "$(cname): memmove DST is not an SSA pointer cell (got " *
                "$(dst_op)); BVM's IntrinsicMemmove needs a Symbol dest_ptr. " *
                "(Bennett-vau9)")
            src_op = _operand(src_v, names; ptr_cells=true)
            src_op isa SSAOperand || _ir_error(inst,
                "$(cname): memmove SRC is not an SSA pointer cell (got " *
                "$(src_op)); BVM's IntrinsicMemmove needs a Symbol src_ptr. " *
                "(Bennett-vau9)")

            return IRCall(dest, :memmove,
                          IROperand[dst_op, src_op, _operand(n_v, names)],
                          Int[64, 64, 64], 64)
        end
        _ir_error(inst,
            "$(cname): memmove is not yet lowered to reversible gates. " *
            "Memmove permits src/dst overlap and reversibility forbids " *
            "destructive in-place overwrite, so static disjointness is " *
            "required and Bennett.jl has no alias analysis to prove it. " *
            "Tracked in Bennett-8bys (Phase 3: byte-granularity / " *
            "variable-size / overlap / memmove); under the closed-world " *
            "`ptr_cells` gate it routes to BVM's overlap-safe " *
            "IntrinsicMemmove instead (Bennett-vau9). " *
            "(Bennett-37mt Phase 1 — memmove deferred to Bennett-8bys)")
    end
    if startswith(cname, "llvm.memcpy.")
        return _handle_memcpy_arm(cname, inst, names, counter, ops, globals;
                                  synth_ptr_provenance=synth_ptr_provenance,
                                  synth_ptr_allocas=synth_ptr_allocas,
                                  ptr_cells=ptr_cells)
    end
    # Bennett-hao Phase 2 (Bennett-9nwt): const-c const-N memset on
    # alloca-i8-backed dst lowers to byte-granular IRPtrOffset+IRStore
    # pairs with ConstOperand(c) at width=8. c=0 takes a separate
    # silent-drop fast path that preserves pre-9nwt benign behaviour.
    if startswith(cname, "llvm.memset.")
        return _handle_memset_arm(cname, inst, names, counter, ops, dest, ptr_cells)
    end
    if startswith(cname, "llvm.cos.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.cos: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-3mo)")
        return IRCall(dest, soft_cos, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-s1zl: `llvm.tan.f64` → `soft_tan` (musl __tan port reusing
    # the rem_pio2 infrastructure; ≤2 ULP vs `Base.tan` across the full
    # Float64 range). f32 rejected per §13. First close in Tier C1 trig
    # completion (Bennett-Enzyme-Parity-NorthStar.md §C1).
    if startswith(cname, "llvm.tan.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.tan: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-s1zl)")
        return IRCall(dest, soft_tan, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-m2bv: `llvm.tanh.f64` → `soft_tanh` (regime-split port of
    # Julia stdlib `Base.tanh`: degree-10 polynomial in x² for |x| ≤ 0.5,
    # `1 - 2/(exp(2|x|)+1)` for medium |x|, ±1 saturation for |x| ≥ 22.
    # ONE soft_exp_fast call total. ≤2 ULP vs `Base.tanh` across the full
    # Float64 range; subnormal-input preserved bit-exactly via the
    # polynomial branch (CLAUDE.md §13). f32 rejected per §13.
    # Tier C1.6 in the Enzyme parity north-star — first hyperbolic close.
    # MUST come AFTER the `llvm.tan.` arm even though the trailing `.`
    # already prevents `startswith("llvm.tan.")` from matching
    # `"llvm.tanh.f64"` (defence-in-depth against future prefix relaxation).
    if startswith(cname, "llvm.tanh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.tanh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-m2bv)")
        return IRCall(dest, soft_tanh, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-m2bv: libm-style `@tanh(double)` external call — what
    # clang/rustc emit when the math intrinsic is disabled or LLVM <18.
    # Same lowering as the intrinsic form. f32 variant `@tanhf` rejected
    # per §13.
    if cname == "tanh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@tanh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-m2bv)")
        return IRCall(dest, soft_tanh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "tanhf"
        _ir_error(inst,
            "@tanhf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-m2bv)")
    end
    # Bennett-ky5n: `llvm.sinh.f64` → `soft_sinh` (regime-split port
    # adapting Julia stdlib `Base.sinh` to use ONE soft_exp_fast call
    # via the unified exp-form `(0.5·E·E - 0.5/(E·E))` with `E = exp(|x|/2)`,
    # plus a degree-8 polynomial in z=x² for `|x| ≤ 1.0` (Julia stdlib
    # minimax coefficients). ≤2 ULP vs `Base.sinh`; subnormal-input
    # preserved bit-exactly via the polynomial branch (CLAUDE.md §13).
    # f32 rejected per §13. Tier C1.7 — second hyperbolic close after
    # Bennett-m2bv (tanh).
    # Defence-in-depth placement: the trailing `.` on `llvm.sin.` already
    # prevents `startswith("llvm.sinh.f64", "llvm.sin.")` from matching
    # (position 8 is `h`, not `.`), so order between sin and sinh arms
    # is semantically free — placed here to group with hyperbolics.
    if startswith(cname, "llvm.sinh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.sinh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-ky5n)")
        return IRCall(dest, soft_sinh, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-ky5n: libm-style `@sinh(double)` external call — what
    # clang/rustc emit when the math intrinsic is disabled or LLVM <18.
    # Same lowering as the intrinsic form. f32 variant `@sinhf` rejected
    # per §13.
    if cname == "sinh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@sinh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-ky5n)")
        return IRCall(dest, soft_sinh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "sinhf"
        _ir_error(inst,
            "@sinhf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-ky5n)")
    end
    # Bennett-bybh: `llvm.cosh.f64` → `soft_cosh` (regime-split port
    # of Julia stdlib `Base.cosh` — even function, polynomial for
    # |x| ≤ 1.0, `(E + 1/E)/2` for medium (no cancellation), `(0.5·E)·E`
    # for huge. ONE soft_exp_fast call total. ≤2 ULP vs `Base.cosh`;
    # subnormal input → 1.0 exactly. f32 rejected per §13.
    # Tier C1.8 — third hyperbolic close after Bennett-m2bv (tanh) and
    # Bennett-ky5n (sinh).
    # Defence-in-depth placement: trailing `.` on `llvm.cos.` already
    # prevents `startswith("llvm.cos.", "llvm.cosh.f64")` from matching
    # (position 8 is `h`, not `.`). Order between cos/cosh arms is
    # semantically free; placed here to group with other hyperbolics.
    if startswith(cname, "llvm.cosh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.cosh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-bybh)")
        return IRCall(dest, soft_cosh, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-bybh: libm-style `@cosh(double)` external call.
    if cname == "cosh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@cosh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-bybh)")
        return IRCall(dest, soft_cosh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "coshf"
        _ir_error(inst,
            "@coshf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-bybh)")
    end
    # Bennett-sfx9: `llvm.asinh.f64` → `soft_asinh` (regime-split port
    # adapting Julia stdlib `Base.asinh` with `log1p` substituted by an
    # extended polynomial regime since Bennett.jl lacks `soft_log1p`).
    # ≤2 ULP vs `Base.asinh`; subnormal-input bit-exact via the
    # polynomial branch. f32 rejected per §13. Tier C1.9 — fourth
    # hyperbolic close.
    if startswith(cname, "llvm.asinh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.asinh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-sfx9)")
        return IRCall(dest, soft_asinh, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-sfx9: libm-style `@asinh(double)` external call.
    if cname == "asinh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@asinh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-sfx9)")
        return IRCall(dest, soft_asinh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "asinhf"
        _ir_error(inst,
            "@asinhf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-sfx9)")
    end
    # Bennett-eq9p: `llvm.acosh.f64` → `soft_acosh` (regime-split port).
    # Domain-restricted (x < 1 → NaN). polynomial via s²-substitution
    # for x ∈ [1, 1.05]; log-based for medium; log+ln2 for huge.
    # f32 rejected per §13. Tier C1.10 — fifth hyperbolic close.
    if startswith(cname, "llvm.acosh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.acosh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-eq9p)")
        return IRCall(dest, soft_acosh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "acosh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@acosh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-eq9p)")
        return IRCall(dest, soft_acosh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "acoshf"
        _ir_error(inst,
            "@acoshf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-eq9p)")
    end
    # Bennett-g82n: `llvm.atanh.f64` → `soft_atanh`. Domain |x| ≤ 1
    # (|x| > 1 → NaN). atanh is ODD. Three regimes: domain / K=25
    # polynomial / log-formula. ONE soft_log + ONE soft_fdiv.
    # Tier C1.11 — FINAL hyperbolic, completes Tier C1 11/11.
    if startswith(cname, "llvm.atanh.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.atanh: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-g82n)")
        return IRCall(dest, soft_atanh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "atanh"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@atanh (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-g82n)")
        return IRCall(dest, soft_atanh, [_operand(ops[1], names)], [w], w)
    end
    if cname == "atanhf"
        _ir_error(inst,
            "@atanhf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-g82n)")
    end
    # Bennett-0ulc: libm `@log1p` external call. The intrinsic
    # `llvm.log1p.f64` arm is up at line 824 (placed beside the
    # `llvm.log` family for the trailing-`.` ordering rationale).
    if cname == "log1p"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@log1p (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-0ulc)")
        return IRCall(dest, soft_log1p, [_operand(ops[1], names)], [w], w)
    end
    if cname == "log1pf"
        _ir_error(inst,
            "@log1pf (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-0ulc)")
    end
    # Bennett-o7cy: `llvm.expm1.f64` → `soft_expm1`. Tier C2.2 — second
    # C2 transcendental, symmetric to log1p (Bennett-0ulc). expm1(x) =
    # exp(x) - 1 accurate for small x. Three-regime branchless: tiny
    # (|x|<2^-54) → x; polynomial (|x|≤0.5) K=15 Taylor; medium (|x|>0.5)
    # → exp(x)-1 directly. f32 rejected per §13.
    if startswith(cname, "llvm.expm1.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.expm1: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-o7cy)")
        return IRCall(dest, soft_expm1, [_operand(ops[1], names)], [w], w)
    end
    if cname == "expm1"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@expm1 (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-o7cy)")
        return IRCall(dest, soft_expm1, [_operand(ops[1], names)], [w], w)
    end
    if cname == "expm1f"
        _ir_error(inst,
            "@expm1f (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-o7cy)")
    end
    # Bennett-7goc: `llvm.atan2.f64` → `soft_atan2` (musl atan2.c port
    # built on soft_atan; ≤2 ULP vs `Base.atan(y, x)`). Tier C1.5 in the
    # Enzyme parity north-star. MUST come before the `llvm.atan.` arm:
    # before Bennett-7goc the (untightened) `startswith("llvm.atan")`
    # silently matched `"llvm.atan2.f64"` and dispatched to soft_atan
    # with just the y operand, dropping x and producing wrong results
    # outside the (y>0, x>0) quadrant. f32 rejected per §13.
    if startswith(cname, "llvm.atan2.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.atan2: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-7goc)")
        return IRCall(dest, soft_atan2,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    # Bennett-7goc: libm-style `@atan2(double, double)` external call —
    # what clang/rustc emit for raw .ll/.bc when the math intrinsic is
    # disabled or LLVM <18. Same lowering as the intrinsic form. The f32
    # variant `@atan2f` is rejected per §13.
    if cname == "atan2"
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "@atan2 (libm): only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-7goc)")
        return IRCall(dest, soft_atan2,
                      [_operand(ops[1], names), _operand(ops[2], names)],
                      [w, w], w)
    end
    if cname == "atan2f"
        _ir_error(inst,
            "@atan2f (libm): f32 transcendentals are not bit-exact " *
            "(CLAUDE.md §13). (Bennett-7goc)")
    end
    # Bennett-qpke: `llvm.atan.f64` → `soft_atan` (musl atan.c branchless
    # port, ≤2 ULP vs `Base.atan` across the full Float64 range). Self-
    # contained — no dependency on `_rp_rem_pio2`. f32 rejected per §13.
    # Tier C1.2 in the Enzyme parity north-star.
    if startswith(cname, "llvm.atan.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.atan: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-qpke)")
        return IRCall(dest, soft_atan, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-ckvj: `llvm.asin.f64` → `soft_asin` (musl asin.c branchless
    # port, ≤2 ULP vs `Base.asin` across [-1, 1]). Shares the rational
    # `_asin_R(z)` helper with `soft_acos` (Bennett-bd7f). f32 rejected
    # per §13. Tier C1.3 in the Enzyme parity north-star.
    if startswith(cname, "llvm.asin.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.asin: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-ckvj)")
        return IRCall(dest, soft_asin, [_operand(ops[1], names)], [w], w)
    end
    # Bennett-bd7f: `llvm.acos.f64` → `soft_acos` (musl acos.c branchless
    # port; reuses `_asin_R(z)` helper from fasin.jl per CLAUDE.md §12).
    # ≤2 ULP vs `Base.acos` across [-1, 1]. f32 rejected per §13.
    # Tier C1.4 in the Enzyme parity north-star.
    if startswith(cname, "llvm.acos.")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.acos: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-bd7f)")
        return IRCall(dest, soft_acos, [_operand(ops[1], names)], [w], w)
    end
    return nothing
end

# Bennett-ares — CW-D2 lever 1: VM-relaxable atomic ordering predicate.
#
# Bennett-4mmt / U14 made EVERY atomic load/store fail loud because reversible
# CIRCUIT compilation has no semantics for ordering. That stays correct for the
# circuit path. But under the closed-world / BennettVM cell model (`ptr_cells=
# true`, sole setter module_walk.jl) the consumer is deterministic, single-
# threaded and history-reversible: there is no concurrent observer, so a
# RELAXED-consistency ordering contract is vacuous and the access can fall
# through to the existing IRLoad/IRStore lowering (no new lowering — the guard
# simply stops throwing).
#
# Accepted band (LLVM AtomicOrdering enum):
#   NotAtomic(0), Unordered(1), Monotonic(2), Acquire(4), Release(5).
# STILL fail-loud (even under the gate):
#   AcquireRelease(6), SequentiallyConsistent(7) — a load/store under one of
#   these is asking for a synchronisation edge the VM model does not provide;
#   relaxing it would silently weaken the source contract. (6 is in fact
#   unconstructible on a plain load/store — LLVM only permits it on atomicrmw/
#   cmpxchg/fence — so its rejection here is defensive for any future reuse.)
# `volatile` is handled by a SEPARATE check above each guard and is NOT relaxed
# under either gate: it is an I/O-effect contract, not an ordering one.
@inline _vm_relaxable_ordering(ord) =
    ord == LLVM.API.LLVMAtomicOrderingNotAtomic   ||
    ord == LLVM.API.LLVMAtomicOrderingUnordered   ||
    ord == LLVM.API.LLVMAtomicOrderingMonotonic   ||
    ord == LLVM.API.LLVMAtomicOrderingAcquire     ||
    ord == LLVM.API.LLVMAtomicOrderingRelease

# Bennett-q04a / 59jj-cut: this function returns a Union of 16 IRInst
# subtypes plus `Nothing` (skip) plus `Vector{IRInst}` (cc0.7 vector
# expansion) — 18 arms, beyond Julia's union-splitting threshold. The
# call site in `_walk_function!` (~line 1003-1018) dispatches via four
# isa-checks: `=== nothing`, `isa Vector`, `isa IRRet||IRBranch||IRSwitch`,
# else. Investigated 2026-04-27 (worklog/047, q04a entry):
#   - Empirical extraction cost: ~1.93 KiB / 7-instruction fn; the per-
#     instruction box from this Union contributes ~5% of the total.
#   - Extraction is one-shot per compile — NOT a runtime hot path.
#   - Splitting into `_convert_instruction_single::IRInst` +
#     `_convert_instruction_expand!(out::Vector{IRInst}, ...)` would
#     eliminate the Vector + Nothing arms but still leaves an abstract-
#     IRInst return (16 concrete subtypes — Julia handles this fine).
#     Refactor blast radius: the function body (1252-2200) plus the
#     caller dispatch — substantial churn for ~5% extraction speedup.
# Decision: doc-only. Contract pinned by `test/test_q04a_convert_instruction_contract.jl`
# (9 assertions): IRInst subtype count = 16, Union arm count bounded
# 10-22, caller dispatch shape pinned, extraction allocation linear in
# instruction count. Re-measure if a workload OOMs during extraction.

# Bennett-xrd6 (Rule 12): the closed-world cell-ABI argument-carry loop, shared
# by the registered-callee `ptr_cells` branch (consumed-call path) AND the
# unregistered C-call arm of the LLVMCall handler. Iterates the operands
# `1:(n_ops-1)` (the last operand is the callee value), carrying every
# `IntegerType` operand at its own bit width and every `PointerType` operand as
# one 64-bit VM cell (ADR 0018 §A — a pointer/sret-out box ptr is one address
# cell). The Julia swiftcc GC-frame synthetic (`ptr nonnull swiftself
# %pgcstack`) is a synthetic frame arg with no VM meaning — identified by its
# call-site `swiftself` attribute (NOT by name, Rule 5) and SKIPPED. This is a
# no-op for genuine C calls (ccall / in-module `.ll` callees carry no swiftself
# attribute), so the C-call arm's behaviour is unchanged for the C-track corpus.
# Any other operand type (float, vector, struct-by-value, token) fails loud
# (CLAUDE.md §1). Pointer/integer constants resolve via `_operand(...;
# ptr_cells=true)` so a `ptr null` arg becomes the zero cell rather than
# crashing — both call sites are already `ptr_cells`-gated.
function _cell_call_args(inst::LLVM.Instruction, ops, n_ops::Int,
                         names::Dict{_LLVMRef, Symbol};
                         skip_sret::Bool=false)
    kind_swiftself = LLVM.API.LLVMGetEnumAttributeKindForName("swiftself", 9)
    # Bennett-416r.17: on the sret-forwarding path (skip_sret=true) the producing
    # call's sret-out box is a local temporary whose aggregate IS the enclosing
    # block's IRRet — NOT a callee value argument. Identify it by its call-site
    # `sret` attribute (Rule 5, never by position) and SKIP it. LangRef permits
    # at most one sret parameter, so exactly one operand is elided. Default
    # (skip_sret=false) never queries the attribute ⇒ existing callers are
    # byte-identical (the consumed-call path carries the box as a genuine cell).
    kind_sret = skip_sret ? LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4) : UInt32(0)
    args = IROperand[]
    widths = Int[]
    for i in 1:(n_ops - 1)
        # Skip the swiftcc GC-frame synthetic (call-site swiftself attribute at
        # this operand's param index). For C calls this is always C_NULL ⇒ no-op.
        LLVM.API.LLVMGetCallSiteEnumAttribute(inst, UInt32(i), kind_swiftself) == C_NULL ||
            continue
        # Bennett-416r.17: elide the sret-out box operand on the forwarding path.
        if skip_sret
            LLVM.API.LLVMGetCallSiteEnumAttribute(inst, UInt32(i), kind_sret) == C_NULL ||
                continue
        end
        op = ops[i]
        ot = LLVM.value_type(op)
        if ot isa LLVM.IntegerType
            push!(args, _operand(op, names; ptr_cells=true))
            push!(widths, Int(LLVM.width(ot)))
        elseif ot isa LLVM.PointerType
            # Pointer ARG = 64-bit cell-address value (ADR 0018 §A).
            push!(args, _operand(op, names; ptr_cells=true))
            push!(widths, 64)
        else
            _ir_error(inst,
                "call argument $(i) has unsupported type $(ot) under ptr_cells; " *
                "only integer and pointer (cell) args are modelled " *
                "(Bennett-xrd6 / BVM ADR 0020 D5)")
        end
    end
    return (args, widths)
end

# Bennett-lbot / Bennett-a70z / CW-D (ADR 0017): fuse an `extractvalue` off an
# overflow-arith intrinsic (`llvm.{smul,umul,sadd,uadd}.with.overflow.iN`, result
# `{iN,i1}`) into scalar IRInsts. The `{iN,i1}` aggregate is never modeled; both
# fields are re-derived directly from the intrinsic call's operands `[a, b, callee]`:
#   - idx 0 (wrapped product/sum) → IRBinOp(dest, :mul|:add, a, b, N)
#   - idx 1 (overflow bit)        → computed EXACTLY when ≥1 operand is a
#     compile-time ConstantInt `c` (Bennett-a70z; formerly walled unless
#     provably zero). With `x` the other operand, the bit is the admissible-
#     interval membership test  bit = (x < L) | (x > U)  where [L, U] is the
#     EXACT no-overflow input interval for (op, signedness, c, N), folded to
#     constants at extraction time (`_ovf_admissible_range`, Int128 arithmetic).
#     SOUNDNESS: mul/add by fixed c is strictly monotone in x, so the LangRef
#     condition "infinite-precision x∘c unrepresentable in iN" is exactly a
#     contiguous-interval complement — the emitted bit agrees with the intrinsic
#     for ALL 2^N inputs; a runtime bit of 1 flows through the already-extracted
#     or-chain into the utzc `:__unreachable__` halt sink, the faithful analogue
#     of the throw the native code takes. Emission: ≤ 2 IRICmp + 1
#     IRBinOp(:or, w=1); constant-false arms (bound at/outside the domain edge)
#     are folded away, so one-sided cases are a single IRICmp carrying the
#     extractvalue's own dest (zero `counter` consumption — klgz determinism).
#
# The lbot fold-to-zero set (MUL c ∈ {0,1} — NOT -1: `smul(INT_MIN,-1)`
# overflows; ADD c = 0) short-circuits to the byte-identical
# IRBinOp(dest,:add,0,0,1) shape of the original lbot fuse. BOTH operands
# constant folds to the literal bit in the same shape (`_ovf_const_bit`).
# TWO DYNAMIC
# operands still FAIL LOUD (general mul-high/add-carry is future work): a
# placeholder-0 would route away from the throw the native code takes — UNSOUND
# (CLAUDE.md §1).
function _fuse_overflow_extractvalue(call, cn, idx, dest, inst, names, counter)
    idx in (0, 1) || _ir_error(inst,
        "extractvalue index $idx out of range for overflow intrinsic $cn " *
        "(only 0=result, 1=overflow-bit). (Bennett-lbot)")
    cops = LLVM.operands(call)            # [a, b, callee]
    a, b = cops[1], cops[2]
    N  = _iwidth(a)
    op = (startswith(cn, "llvm.smul") || startswith(cn, "llvm.umul")) ? :mul : :add
    if idx == 0
        # Wrapped product/sum: the scalar iN arithmetic (N-bit two's-complement
        # wrap matches the intrinsic's low-N-bits result field).
        return IRBinOp(dest, op, _operand(a, names), _operand(b, names), N)
    end
    # idx == 1: overflow bit — exact for a constant operand, else FAIL LOUD.
    # mul/add are commutative: whichever operand is ConstantInt is `c` (`b`
    # checked first — Julia's memorynew shape puts the elsize there — but no
    # reliance on operand order, Rule 5).
    signed = startswith(cn, "llvm.s")
    ca = a isa LLVM.ConstantInt ? _const_int_as_int(a) : nothing
    cb = b isa LLVM.ConstantInt ? _const_int_as_int(b) : nothing
    if ca !== nothing && cb !== nothing
        # BOTH operands constant → fold to the LITERAL exact bit (proposal B
        # `_ovf_const_bit`). Deliberate (Bennett-a70z D3): the interval path
        # would emit `IRICmp(ConstOperand, ConstOperand)`, whose only consumer
        # on this gate is BennettVM's ingest (ptr_cells=true never reaches
        # src/lowering/) — an out-of-repo shape this repo cannot verify. The
        # literal fold reuses the SAME `IRBinOp(dest,:add,const,const,1)` shape
        # BVM already ingests today on the fold-to-zero path, is exact by
        # construction, and consumes no `counter` names (klgz determinism).
        bit = _ovf_const_bit(op, ca, cb, N, signed)
        return IRBinOp(dest, :add, iconst(bit), iconst(0), _iwidth(inst))
    elseif cb !== nothing
        xv, c = a, cb
    elseif ca !== nothing
        xv, c = b, ca
    else
        _ir_error(inst,
            "overflow bit of $cn with two dynamic operands ($(string(a)), $(string(b))) " *
            "is unsupported — the exact bit (Bennett-a70z) needs one compile-time-constant " *
            "operand; general mul-high/add-carry computation is future work. A placeholder-0 " *
            "would route away from the throw the native code takes and is UNSOUND. (Bennett-lbot)")
    end
    L, U, always0 = _ovf_admissible_range(op, c, N, signed)
    # Fold-to-zero fast path: byte-identical to the lbot shape, zero counter
    # consumption. The overflow bit is field 1 of `{iN,i1}` — `_iwidth(inst)` == 1.
    always0 && return IRBinOp(dest, :add, iconst(0), iconst(0), _iwidth(inst))
    xop = _operand(xv, names)
    lt = signed ? :slt : :ult
    gt = signed ? :sgt : :ugt
    if L !== nothing && U !== nothing
        t1 = _auto_name(counter)
        t2 = _auto_name(counter)
        return IRInst[IRICmp(t1, lt, xop, iconst(_ovf_bound_const(L, N)), N),
                      IRICmp(t2, gt, xop, iconst(_ovf_bound_const(U, N)), N),
                      IRBinOp(dest, :or, ssa(t1), ssa(t2), _iwidth(inst))]
    elseif L !== nothing
        return IRICmp(dest, lt, xop, iconst(_ovf_bound_const(L, N)), N)
    else
        return IRICmp(dest, gt, xop, iconst(_ovf_bound_const(U, N)), N)
    end
end

# Bennett-a70z: the EXACT no-overflow input interval of `x ∘ c` at width N.
# Returns `(L, U, always0)`: the dynamic operand overflows iff
# `x < L || x > U` (each `nothing` when that arm is constant-false over the
# whole iN domain, i.e. the bound lies at/outside the domain edge);
# `always0 = true` iff the bit is identically 0 (mul c ∈ {0,1}, add c = 0).
# All arithmetic in Int128 so the PROVER cannot overflow (every operand
# magnitude ≤ 2^64; in particular `fld(typemin,-1)`-style traps are impossible).
# `c` arrives SIGN-EXTENDED (`_const_int_as_int` uses LLVMConstIntGetSExtValue);
# unsigned intrinsics re-decode it by masking to the low N bits. Derivation
# (LangRef: bit = infinite-precision x∘c ∉ domain; x ↦ x∘c strictly monotone,
# antitone for c < 0, so dividing/shifting the domain inequalities by c gives):
#   smul c>0: [cld(smin,c), fld(smax,c)]   smul c<0: [cld(smax,c), fld(smin,c)]
#   umul c≥2: [0, fld(umax,c)]             sadd:     [smin-c, smax-c]
#   uadd c≥1: [0, umax-c]
# Edge cases covered by the same formulas (pinned in test_a70z_*):
#   c = -1   → [smin+1, 2^(N-1)→folds]: bit ⟺ x == typemin (smul(INT_MIN,-1))
#   c = smin → [0, 1]: only x ∈ {0,1} avoid overflow.
function _ovf_admissible_range(op::Symbol, c::Int, N::Int, signed::Bool)
    1 <= N <= 64 || error(
        "ir_extract.jl: _ovf_admissible_range: width $N out of range (Bennett-a70z)")
    umax = (Int128(1) << N) - 1
    smin = -(Int128(1) << (N - 1))
    smax = (Int128(1) << (N - 1)) - 1
    local L::Int128, U::Int128, dlo::Int128, dhi::Int128
    if signed
        sc = Int128(c)
        dlo, dhi = smin, smax
        if op === :mul
            (sc == 0 || sc == 1) && return (nothing, nothing, true)
            L = sc > 0 ? cld(smin, sc) : cld(smax, sc)
            U = sc > 0 ? fld(smax, sc) : fld(smin, sc)
        else  # :add
            sc == 0 && return (nothing, nothing, true)
            L = smin - sc
            U = smax - sc
        end
    else
        uc = Int128(c) & umax                 # masked (unsigned) decode
        dlo, dhi = Int128(0), umax
        if op === :mul
            (uc == 0 || uc == 1) && return (nothing, nothing, true)
            L = dlo
            U = fld(umax, uc)
        else  # :add
            uc == 0 && return (nothing, nothing, true)
            L = dlo
            U = umax - uc
        end
    end
    # Clamp-fold: an arm whose bound is at/outside the domain edge is a
    # constant-false comparison over every representable x — drop it.
    lo = L <= dlo ? nothing : L
    hi = U >= dhi ? nothing : U
    lo === nothing && hi === nothing && return (nothing, nothing, true)
    return (lo, hi, false)
end

# Bennett-a70z: encode an interval bound as a ConstOperand value — the low N
# bits, sign-extended to Int64 (the project-wide sext ConstOperand convention,
# matching `_const_int_as_int`). Needed because unsigned-i64 bounds (e.g.
# uadd(x,1): U = 2^64-2) exceed typemax(Int64) as mathematical integers; the
# bit-pattern encoding is faithful since every surviving bound lies strictly
# inside its iN domain.
function _ovf_bound_const(b::Int128, N::Int)
    u = UInt64(b & ((Int128(1) << N) - 1))    # low N bits, nonnegative
    s = 64 - N
    return Int(reinterpret(Int64, u << s) >> s)
end

# Bennett-a70z (D3): both operands compile-time constants → the exact overflow
# bit is a LITERAL, evaluated in Int128 (`|x·c| ≤ 2^126` for N ≤ 64, so the
# evaluation itself cannot overflow). `ca`/`cb` arrive SIGN-EXTENDED from width
# N (`_const_int_as_int`); unsigned arms re-decode by masking, exactly as
# `_ovf_admissible_range` does. Returns 0 or 1 (LangRef: the bit is set iff the
# infinite-precision result is unrepresentable in the iN domain).
function _ovf_const_bit(op::Symbol, ca::Int, cb::Int, N::Int, signed::Bool)
    1 <= N <= 64 || error(
        "ir_extract.jl: _ovf_const_bit: width $N out of range (Bennett-a70z)")
    if signed
        x, y = Int128(ca), Int128(cb)
        lo = -(Int128(1) << (N - 1))
        hi = (Int128(1) << (N - 1)) - 1
    else
        m = (Int128(1) << N) - 1
        x, y = Int128(ca) & m, Int128(cb) & m
        lo, hi = Int128(0), m
    end
    r = op === :mul ? x * y : x + y
    return (r < lo || r > hi) ? 1 : 0
end


# Bennett-40ys: the Bennett-xrd6 registered-callee cell-ABI emission, HOISTED
# out of `_convert_instruction` so it can be shared by the two callee-resolution
# arms that both need it (Rule 12 — no duplicated lowering):
#
#   * `_lookup_callee` hit  — a registered Julia `Function` callee;
#   * `_lookup_callee_name` hit — an INSTANCE-LESS callee (closure / functor)
#     registered by NAME only, because no `Function` value exists to register
#     (see `callees.jl`'s Bennett-40ys section).
#
# `callee` is therefore `Union{Function, Symbol}` — exactly the `IRCall.callee`
# union (Bennett-k3ej / BVM ADR 0020 D1). The body is otherwise VERBATIM the
# pre-hoist xrd6 arm, so its existing tests continue to pin it unchanged.
function _emit_cell_call(inst::LLVM.Instruction, ops, n_ops::Int,
                         names::Dict{_LLVMRef, Symbol}, cname::AbstractString,
                         dest::Symbol, callee::Union{Function, Symbol})
    # Bennett-xrd6: closed-world cell ABI for a registered callee
    # whose result is CONSUMED locally (read back from an sret-out
    # box, or used as a returned cell) — NOT gate-inlined. Carries
    # pointer args (incl. the sret-out box ptr as arg 1) as 64-bit
    # VM cells so the read-back loads of the box resolve, and uses
    # the void/ptr → 64 ret_width SENTINEL: an sret-convention call
    # has a `void` LLVM return, and a Dict-returning call a `ptr`
    # return — neither has a scalar width of its own. The Function
    # callee is kept (clean nameof for closed-world linkage); the
    # IRCall shape is identical to the C-track / isolation D5 form
    # BennettVM already consumes.
    #
    # Fail-loud (CLAUDE.md §1): if this is an sret-convention call,
    # validate the sret pointee is a fixed-width integer bits-struct
    # (reusing the Bennett-dv1z `_sret_struct_fields` rules: reject
    # non-StructType pointee, packed structs, non-integer fields,
    # widths ∉ {8,16,32,64}) BEFORE trusting the read-back machinery
    # to unpack the box. A genuinely-unsupported sret shape rejects
    # here, never silently miscompiles.
    kind_sret = LLVM.API.LLVMGetEnumAttributeKindForName("sret", 4)
    asret = LLVM.API.LLVMGetCallSiteEnumAttribute(inst, UInt32(1), kind_sret)
    if asret != C_NULL
        pointee = LLVM.LLVMType(LLVM.API.LLVMGetTypeAttributeValue(asret))
        pointee isa LLVM.StructType || _ir_error(inst,
            "sret-convention call to '$(cname)' has pointee " *
            "$(pointee); only fixed-width integer bits-struct sret " *
            "pointees (e.g. {i64,i8}) are modelled on the " *
            "consumed-call path (Bennett-xrd6)")
        # Side-effecting validation (return discarded): rejects
        # packed / non-integer / bad-width fields loud (Bennett-dv1z).
        # Bennett-7wsz: `ptr_cells=true` is STRUCTURAL here — `_emit_cell_call`
        # is the cell ABI arm by construction (both call sites gate on
        # `ptr_cells`), so a ptr sret FIELD is admitted as a 64-bit cell.
        _sret_struct_fields(pointee, LLVM.parent(LLVM.parent(inst));
                            ptr_cells=true)
    end
    cell_args, cell_widths = _cell_call_args(inst, ops, n_ops, names)
    rt = LLVM.value_type(inst)
    ret_w = if rt isa LLVM.VoidType || rt isa LLVM.PointerType
        64                       # void sret call / ptr-returning call
    elseif rt isa LLVM.IntegerType
        Int(LLVM.width(rt))
    elseif rt isa LLVM.ArrayType
        _type_width(rt)          # NTuple [N x iM] wide return
    else
        _ir_error(inst,
            "registered call to '$(cname)' has unsupported return " *
            "type $(rt) under ptr_cells; only void, integer, " *
            "pointer (cell), and [N x iM] aggregate returns are " *
            "modelled (Bennett-xrd6). A by-value StructType return " *
            "must use the sret convention.")
    end
    return IRCall(dest, callee, cell_args, cell_widths, ret_w)
end

function _convert_instruction(inst::LLVM.Instruction, names::Dict{_LLVMRef, Symbol},
                              counter::Ref{Int},
                              lanes::Dict{_LLVMRef, Vector{IROperand}}=Dict{_LLVMRef, Vector{IROperand}}();
                              globals::Dict{Symbol, Tuple{Vector{UInt64}, Int}}=
                                  Dict{Symbol, Tuple{Vector{UInt64}, Int}}(),
                              synth_ptr_provenance::Set{Tuple{Symbol, Int, Int}}=
                                  Set{Tuple{Symbol, Int, Int}}(),
                              synth_ptr_allocas::Set{_LLVMRef}=Set{_LLVMRef}(),
                              # BVM ADR 0020 D3/D4 (CW-C2 chunk B): C-track gate.
                              # When true, `store ptr`/`load ptr` lower as 64-bit
                              # cell IRStore/IRLoad and a two-index struct GEP
                              # lowers to IRPtrOffset(elem_width=64). Default false
                              # keeps the U114 store / U16 GEP fail-louds firing
                              # byte-identically (they guard the circuit/:heap
                              # models). The C cell model must not silently alias
                              # those paths — `module_walk.jl` is the sole setter.
                              ptr_cells::Bool=false,
                              # Bennett-p06b D1b: the refs `module_walk.jl`'s
                              # emission loop `continue`s past (sret box allocas
                              # and their producing calls / consumed-sret boxes).
                              # A NAMED but NEVER-EMITTED instruction is not a
                              # materialised cell; the p06b target certification
                              # must consult what the walk actually emitted.
                              suppressed_refs::Set{_LLVMRef}=Set{_LLVMRef}(),
                              # Bennett-iwo9 / CW-D3 Lever 1: extraction-local
                              # type-tag interning. `tag_ids` maps a canonical
                              # type path ("Main.Base.Dict") → dense Int64 id
                              # (first-seen walk order, deterministic). `tag_ssa`
                              # records the SSA dests that carry a type-tag value
                              # (provenance), so a downstream ptrtoint/inttoptr
                              # whose source is a tag is recognised as the sound
                              # type-tag round-trip. Both threaded from
                              # `module_walk.jl` (the sole owner) and mutated in
                              # place. Only consulted under `ptr_cells=true`.
                              tag_ids::Dict{String, Int64}=Dict{String, Int64}(),
                              tag_ssa::Set{_LLVMRef}=Set{_LLVMRef}(),
                              # Bennett-3vf2 / CW-D: the Bennett-utzc pruner's
                              # dead-block set for THIS function, threaded from
                              # `module_walk.jl` (the sole owner — it computes it
                              # once at :426, BEFORE the first instruction is
                              # converted, and is itself ptr_cells-gated so the
                              # set is EMPTY at ptr_cells=false). Consulted only
                              # by the dead-use drop in the load handler. The
                              # empty default keeps the two non-module_walk
                              # callers (`heap.jl`, `vector_vm_cfg.jl`, neither of
                              # which forwards `ptr_cells` either) byte-identical.
                              dead_blocks::Set{_LLVMRef}=Set{_LLVMRef}())
    opc = LLVM.opcode(inst)
    dest = names[inst.ref]

    # Bennett-cc0.7: SLP-vectorised IR. `<N x iM>` SSA is modelled as N scalar
    # per-lane IROperands in `lanes`; vector ops desugar into N scalar IRInsts.
    # See `docs/design/cc07_consensus.md`. Entire mechanism is contained in
    # this file — `lower.jl` never sees a vector.
    #
    # `_any_vector_operand` catches pre-existing cc0.3 (LLVMGlobalAlias) errors
    # that fire during operand iteration for call instructions (LLVM.jl's
    # LLVM.Value wrapper refuses to materialise GlobalAlias values). Callees
    # are never vectors, so treat iterator exceptions as "no".
    is_vec_result = _safe_is_vector_type(inst)
    if is_vec_result || _any_vector_operand(inst)
        return _convert_vector_instruction(inst, names, lanes, counter)
    end

    # binary arithmetic/logic
    if opc in (LLVM.API.LLVMAdd, LLVM.API.LLVMSub, LLVM.API.LLVMMul,
               LLVM.API.LLVMAnd, LLVM.API.LLVMOr,  LLVM.API.LLVMXor,
               LLVM.API.LLVMShl, LLVM.API.LLVMLShr, LLVM.API.LLVMAShr)
        ops = LLVM.operands(inst)
        return IRBinOp(dest, _opcode_to_sym(opc),
                       _operand(ops[1], names), _operand(ops[2], names),
                       _iwidth(inst))
    end

    # icmp
    if opc == LLVM.API.LLVMICmp
        ops  = LLVM.operands(inst)
        pred = _pred_to_sym(LLVM.predicate(inst))
        # Bennett-8g7m / CW-D: pointer-typed icmp under the closed-world
        # `ptr_cells` gate. A ptr operand is one Int64 VM cell (ADR 0018 §A,
        # width 64); a `ptr null` lowers to the zero cell via
        # `_operand(...; ptr_cells=true)` (Bennett-beaw — the helper already
        # does null->iconst(0) under the gate). Only eq/ne is deterministic
        # over cell ADDRESSES; an ordering compare is an address-MAGNITUDE
        # comparison whose result depends on the BVM allocation layout (UB
        # across allocations in C) — FAIL LOUD (Rule 1). Mirrors the ret/store
        # beaw arms. Gate defaults false, so the circuit / Julia paths keep the
        # byte-identical integer path below (`_iwidth(ops[1])`); the guard is
        # the gate AND the PointerType operand check, so a non-pointer integer
        # icmp (e.g. `icmp slt i32`) is never caught here.
        if ptr_cells && (LLVM.value_type(ops[1]) isa LLVM.PointerType ||
                         LLVM.value_type(ops[2]) isa LLVM.PointerType)
            pred in (:eq, :ne) || _ir_error(inst,
                "icmp predicate :$pred over pointer operands under ptr_cells — " *
                "only :eq/:ne are deterministic over VM cell addresses; " *
                "ordering predicates compare address magnitudes, which depend " *
                "on the BVM allocation layout (not a source-level property) and " *
                "risk a silent miscompile. (Bennett-8g7m / U80)")
            return IRICmp(dest, pred,
                          _operand(ops[1], names; ptr_cells=true),
                          _operand(ops[2], names; ptr_cells=true), 64)
        end
        return IRICmp(dest, pred,
                      _operand(ops[1], names), _operand(ops[2], names),
                      _iwidth(ops[1]))
    end

    # select
    if opc == LLVM.API.LLVMSelect
        ops = LLVM.operands(inst)
        # Bennett-cc0 M2b: pointer-typed select uses width=0 sentinel.
        # Pointers don't materialize as wires — routing is recorded in
        # ptr_provenance at lowering time. _type_width stays fail-loud
        # for any other unexpected pointer use (load, binop, etc.).
        w = LLVM.value_type(inst) isa LLVM.PointerType ? 0 : _iwidth(inst)
        return IRSelect(dest, _operand(ops[1], names),
                        _operand(ops[2], names), _operand(ops[3], names), w)
    end

    # phi
    if opc == LLVM.API.LLVMPHI
        incoming = Tuple{IROperand, Symbol}[]
        for (val, blk) in LLVM.incoming(inst)
            # Bennett-yd4f / U80 / CW-D (ADR 0017): under the closed-world
            # `ptr_cells` gate ONLY, an INTEGER `undef` in phi-INCOMING position
            # is LLVM's compiler-proven don't-care on a dynamically-dead edge
            # (LangRef: undef as a phi operand). BennettVM resolves phis by the
            # TAKEN predecessor edge (BennettVM/src/ir/ingest_phi.jl:84), so a
            # `0` placeholder on a dead incoming is never materialised at
            # runtime. Model it as the zero cell `iconst(0)` (mirrors the beaw
            # ptr-null lever, helpers.jl:184, and the existing vec_vm dead-edge
            # substitution at vector_vm_term.jl:112). Gated HERE, not in
            # `_operand`, because undef→0 is position-DEPENDENT (sound only in
            # phi-incoming); every other operand position keeps `_operand`'s
            # undef fail-loud (helpers.jl:167). PoisonValue is a DISTINCT LLVM.jl
            # type (sibling of UndefValue, not a subtype), so it is NOT caught
            # here and stays fail-loud; a non-integer undef falls through to
            # `_operand` and stays fail-loud. `ptr_cells=false` (circuit/:heap)
            # is byte-identical fail-loud.
            op = (ptr_cells && val isa LLVM.UndefValue &&
                  LLVM.value_type(val) isa LLVM.IntegerType) ?
                 iconst(0) : _operand(val, names)
            push!(incoming, (op, Symbol(LLVM.name(blk))))
        end
        # Bennett-cc0 M2b: pointer-typed phi uses width=0 sentinel.
        w = LLVM.value_type(inst) isa LLVM.PointerType ? 0 : _iwidth(inst)
        return IRPhi(dest, w, incoming)
    end

    # casts
    # division and remainder
    if opc in (LLVM.API.LLVMUDiv, LLVM.API.LLVMSDiv, LLVM.API.LLVMURem, LLVM.API.LLVMSRem)
        opname = opc == LLVM.API.LLVMUDiv ? :udiv :
                 opc == LLVM.API.LLVMSDiv ? :sdiv :
                 opc == LLVM.API.LLVMURem ? :urem : :srem
        ops = LLVM.operands(inst)
        return IRBinOp(dest, opname, _operand(ops[1], names), _operand(ops[2], names), _iwidth(inst))
    end

    if opc in (LLVM.API.LLVMSExt, LLVM.API.LLVMZExt, LLVM.API.LLVMTrunc)
        opname = opc == LLVM.API.LLVMSExt ? :sext :
                 opc == LLVM.API.LLVMZExt ? :zext : :trunc
        src = LLVM.operands(inst)[1]
        return IRCast(dest, opname, _operand(src, names), _iwidth(src), _iwidth(inst))
    end

    # Bennett-iwo9 / CW-D3 Lever 1: ptrtoint / inttoptr — model ONLY the Julia
    # type-tag round-trip under the closed-world `ptr_cells` gate. The cluster
    # the fdict root hits is
    #
    #   %tag  = load ptr, ptr @"+Main.Base.Dict#148"   ; → tag_ssa (load arm)
    #   %Dict = ptrtoint ptr %tag to i64               ; src ∈ tag_ssa
    #   %1    = inttoptr i64 %Dict to ptr              ; src ∈ tag_ssa
    #
    # Each link is a width-64 identity `IRBinOp(dest, :or, <src>, iconst(0), 64)`
    # so the dest binds through the normal SSA path (consensus decision 3 —
    # real SSA defs, not zero-IR const-prop). If the source SSA is a recognised
    # type tag (`∈ tag_ssa`) the dest inherits tag provenance; OTHERWISE fail
    # loud — a genuine pointer↔int round-trip (casting a real arena pointer,
    # `ptrtoint ptr→i32`, etc.) is NOT modelled (it would expose
    # ARENA_BASE-relative addresses to integer arithmetic). Under
    # `ptr_cells=false` there is NO arm: the opcode falls through to the
    # existing "unsupported LLVM opcode" fail-loud → circuit path byte-identical.
    if (opc == LLVM.API.LLVMPtrToInt || opc == LLVM.API.LLVMIntToPtr) && ptr_cells
        src = LLVM.operands(inst)[1]
        opname = opc == LLVM.API.LLVMPtrToInt ? "ptrtoint" : "inttoptr"
        if src isa LLVM.Instruction && src.ref in tag_ssa
            # Width guard: the type-tag round-trip is a 64-bit VM-cell identity
            # (ADR 0018 §A — a tag is one Int64 cell). A cast to/from a NON-64-bit
            # width (e.g. `ptrtoint ptr %tag to i32`) is NOT this round-trip — it
            # is genuine pointer arithmetic that would truncate/extend the cell
            # value. It can't occur in the real fdict cluster (tags are always
            # 64-bit round-trips), but a core extractor arm must not hardcode a
            # width it didn't verify. PointerType has no integer width → 64 (cell).
            srt = LLVM.value_type(src)
            drt = LLVM.value_type(inst)
            src_w = srt isa LLVM.PointerType ? 64 : _iwidth(src)
            dst_w = drt isa LLVM.PointerType ? 64 : _iwidth(inst)
            (src_w == 64 && dst_w == 64) || _ir_error(inst,
                "$(opname) under ptr_cells on a type-tag value at a NON-64-bit " *
                "width (src=$(src_w), dst=$(dst_w)) (Bennett-iwo9 / CW-D3 " *
                "Lever 1). Only the 64-bit type-tag round-trip is modelled (a " *
                "type tag is one Int64 VM cell); a narrower pointer↔integer cast " *
                "is genuine pointer arithmetic that truncates/extends the cell " *
                "value and is rejected to fail fast (CLAUDE.md §1).")
            push!(tag_ssa, inst.ref)
            return IRBinOp(dest, :or, _operand(src, names), iconst(0), 64)
        end
        # Bennett-583s / CW-D: `ptrtoint ptr %memory_data to i64` — the Julia
        # GenericMemory `.data` base pointer — admitted as a width-64 cell
        # identity BUT ONLY when confined to a same-Memory base-cancelling bounds
        # check (`sub(ptrtoint(P_elem), ptrtoint(P_base))` where both operands
        # trace to the SAME Memory `.data` root). Soundness (ADR 0017 CW-D): the
        # base cancels in `sub(ptrtoint(base+off), ptrtoint(base)) = off`, so the
        # net effect is base-INDEPENDENT → matches the native oracle; the `oob`
        # block is a dead `@boundscheck` throw. Any escaping / base-DEPENDENT use
        # (inttoptr-back-to-deref, store-of-int, hash, cross-allocation diff,
        # width≠64) would break oracle match (the bennettvm-90l hazard) and stays
        # fail-loud. `inttoptr` of a `.data` base is itself the forbidden escape,
        # so this arm is `LLVMPtrToInt`-only — an `inttoptr` falls through to the
        # iwo9 fail-loud below. Sits inside the `&& ptr_cells` block, so the
        # circuit path is byte-identical (no arm at all → the ptrtoint opcode
        # hits the pre-existing "unsupported LLVM opcode" wall).
        #
        # Bennett-foz5 / CW-D (ADR 0017 §4a): the arm's ENTRY and its ADMISSION
        # each gain a SECOND DISJUNCT — the CONFINED-VALUE contract. 583s keeps
        # FIRST REFUSAL in both (`||` short-circuits), so every cluster the
        # base-cancellation proof owns is decided byte-identically and the
        # confined contract is never consulted for it. The second disjunct is
        # gated on the ptrtoint's USE SHAPE, not on its source provenance:
        # `_memdata_root` is NOT widened (that widening was measured to steal
        # jbko's `%L84` witness — see the foz5 helper block above).
        #
        # THE ARM STILL ALWAYS RETURNS OR ERRORS. `_foz5_confined_dead_bounds`
        # is pure, so entry-via-confinement IMPLIES admission-via-confinement:
        # foz5 introduces NO fall-through, and the jbko
        # `_memdata_root(src) === nothing` pin below therefore keeps its exact
        # current meaning and its exact current status (redundant today,
        # load-bearing the moment 583s grows a fall-through).
        # Bennett-57hd / CW-D (ADR 0017 §4b): the arm's ENTRY and its ADMISSION
        # each gain a THIRD DISJUNCT — the VALUE-IDENTITY contract. Order of
        # refusal is 583s -> §4a -> §4b, so no cluster an existing contract
        # owns can change hands.
        #
        # THE ENTRY DISJUNCT IS LOAD-BEARING, NOT SYMMETRY, AND IT WAS
        # MEASURED. `.ll` surgery admitting only the corpus's `%12` and leaving
        # `%13` walls IMMEDIATELY on `%13` in the JBKO arm ("found a use that
        # is a `sub`, not an icmp"), because `%13`'s source has
        # `_memdata_root === nothing` and fails §4a clause (iii). A cluster is
        # a PAIR: both coercions must enter here or the bead clears nothing.
        # Pinned by gate (P) of `test/test_57hd_value_identity.jl`.
        if opc == LLVM.API.LLVMPtrToInt && src isa LLVM.Instruction &&
           (_memdata_root(src) !== nothing ||
            _foz5_confined_dead_bounds(inst, names, suppressed_refs, dead_blocks) ||
            _57hd_value_identity_cluster(inst, names, suppressed_refs, ptr_cells))
            srt = LLVM.value_type(src)
            drt = LLVM.value_type(inst)
            src_w = srt isa LLVM.PointerType ? 64 : _iwidth(src)
            dst_w = drt isa LLVM.PointerType ? 64 : _iwidth(inst)
            # SOURCE-AGNOSTIC WORDING (the a8nw review-D5 defect class, which
            # jbko already fixed for itself): under the foz5 entry disjunct a
            # NON-memdata source reaches this check, so the message must not
            # assert the pointer is a `GenericMemory .data` base — nothing has
            # established that. Gate (3) of `test_583s_memdata_bounds.jl` pins
            # the substrings "583s" and "width"/"64"; keep them on any reword.
            (src_w == 64 && dst_w == 64) || _ir_error(inst,
                "ptrtoint under ptr_cells at a NON-64-bit width " *
                "(src=$(src_w) dst=$(dst_w)) — genuine pointer arithmetic, not a " *
                "cell identity (Bennett-583s / CW-D; Bennett-foz5). A pointer is " *
                "ONE Int64 VM cell (ADR 0018 §A); only the 64-bit round-trip — " *
                "confined either to a base-cancelling bounds check " *
                "(`_verify_memdata_bounds_cluster`) or to a dead-throw bounds " *
                "check (`_foz5_confined_dead_bounds`), or PROVED to difference " *
                "two copies of ONE POINTER VALUE " *
                "(`_57hd_value_identity_cluster`) — is modelled, because a " *
                "narrower cast truncates the cell value (CLAUDE.md §1).")
            (_verify_memdata_bounds_cluster(inst, src) ||
             _foz5_confined_dead_bounds(inst, names, suppressed_refs, dead_blocks) ||
             _57hd_value_identity_cluster(inst, names, suppressed_refs, ptr_cells)) ||
                _ir_error(inst,
                "ptrtoint of a GenericMemory .data base under ptr_cells whose " *
                "result is NOT confined to a same-Memory base-cancelling bounds " *
                "check (a use is not a same-root sub(ptrtoint,ptrtoint); e.g. " *
                "inttoptr-deref, store, hash, or a cross-allocation difference) " *
                "— predicate `_verify_memdata_bounds_cluster`. An escaping " *
                "base-dependent address would break oracle match " *
                "(Bennett-583s / CW-D; CLAUDE.md §1). AND its result is not " *
                "CONFINED to a dead-throw bounds check either — predicate " *
                "`_foz5_confined_dead_bounds` (Bennett-foz5 / ADR 0017 §4a): " *
                "the source must be a certified materialised cell and EVERY use " *
                "must run sub(ptrtoint,ptrtoint) → icmp → i1-and/or/xor → a " *
                "conditional br with a utzc-pruned `:__unreachable__` successor, " *
                "so that a value we cannot prove equals the native oracle can " *
                "only ever choose a branch that halts loudly. AND its two " *
                "coerced pointers are not PROVED to be COPIES OF ONE VALUE " *
                "either — predicate `_57hd_value_identity_cluster` " *
                "(Bennett-57hd / ADR 0017 §4b): every use must be an i64 " *
                "sub(ptrtoint, ptrtoint) whose two sources are certified cell " *
                "producers in ONE basic block that reduce to the SAME " *
                "canonical value under the straight-line copy analysis " *
                "(aggregate-store field forwarding, same-slot reload, and a " *
                "no-clobber scan whose call effects come from the LLVM " *
                "`memory` attribute and whose object disjointness comes from " *
                "`noalias` / `nocapture`), so that the difference is " *
                "IDENTICALLY ZERO in both worlds and may therefore escape " *
                "freely. A call with an unmodelled effect, a variable-length " *
                "copy, an uncertified store target, or a cross-block window " *
                "terminates the walk and lands here (CLAUDE.md §1).")
            return IRBinOp(dest, :or, _operand(src, names), iconst(0), 64)
        end
        # Bennett-jbko / CW-D: IDENTITY-USE ptrtoint. Julia's `MemoryRef`
        # concurrent-mutation guard (`_growend!` `%L84`) compares a MemoryRef's
        # CURRENT data pointer against a CAPTURED copy of it that codegen read
        # back as a plain `i64`:
        #
        #   %po = extractvalue { ptr, ptr } %.ref, 0     ; current data ptr
        #   %cap = load i64, ptr %self_plus_56           ; captured copy (a CELL)
        #   %c  = ptrtoint ptr %po to i64                ; <-- THIS ARM
        #   %eq = icmp eq i64 %cap, %c                   ; the ONLY use of %c
        #
        # Admitted as the width-64 cell identity iff (P1) both widths are 64,
        # (P2) the source is a CERTIFIED cell-valued pointer SSA
        # (`_jbko_cell_ptr_src_kind`), and (P3)+(P4) every use is an
        # `icmp eq`/`ne` against an in-model value or the zero cell
        # (`_jbko_identity_use_violation`). The full determinism argument is in
        # the helper block above `_jbko_cell_ptr_src_kind`.
        #
        # THE USE GATE IS LOAD-BEARING: Bennett-8g7m's ordering-reject is
        # TYPE-based (it fires only when an icmp operand has PointerType), so an
        # UNGATED ptrtoint would launder an address-MAGNITUDE compare onto the
        # plain-integer icmp path and silently disable 8g7m. Do not "simplify"
        # it away — `test_jbko_ptr_identity_icmp.jl` gate (C) is the pin.
        #
        # PLACEMENT: this arm sits AFTER the 583s arm and is additionally pinned
        # by `_memdata_root(src) === nothing`, so the two contracts are disjoint
        # OVER THE SHAPES `_memdata_root` RECOGNISES, regardless of ordering: any
        # source it roots stays 583s's, under 583s's own (subtraction) proof and
        # its own reject messages. That is NOT the stronger claim "no `.data`
        # base ever reaches this arm" (a8nw review D3): `_memdata_root` follows
        # only a `load` of a `{i64,ptr}` field-1 GEP, the i8 byte-offset GEP, and
        # identity casts, so a `.data` base LAUNDERED through e.g. an
        # `insertvalue`/`extractvalue` round-trip escapes it and DOES land here
        # (a8nw probe P10). It is admitted SOUNDLY when it does — this arm's
        # equality argument is about the USES, and does not care where the
        # pointer came from (subject to the sibling RESIDUAL RISK disclosed at
        # the determinism argument above; probe P10's own fixture compares
        # against an i64 argument and sits under that residual) — but it is
        # admitted under jbko's contract, not 583s's.
        #
        # The `_memdata_root(src) === nothing` pin is REDUNDANT today: the 583s
        # arm above always returns or errors, so nothing memdata-rooted can
        # reach this line at all. Keep it: it becomes LOAD-BEARING the moment
        # 583s grows a non-terminating (fall-through) arm, which is exactly what
        # a ROOT extension would introduce (relevant to Bennett-foz5).
        #
        # BENNETT-foz5 LANDED, AND THIS NOTE STILL HOLDS LITERALLY. foz5 was
        # scoped as that ROOT extension and did NOT land as one: a root widening
        # was measured to STEAL this arm's `%L84` corpus witness (probe
        # `p07_steal.jl`), so foz5 instead gave the 583s arm a second
        # USE-SHAPED disjunct (`_foz5_confined_dead_bounds`) and left
        # `_memdata_root` byte-for-byte untouched. Because that predicate is
        # PURE, entry-via-confinement implies admission-via-confinement, so the
        # 583s arm STILL always returns or errors — no fall-through was
        # introduced and this pin stays redundant rather than becoming a
        # BLOCKER. The two arms are additionally disjoint by a STRUCTURAL
        # argument now, independent of ordering and of `_memdata_root`: foz5
        # requires EVERY use of the ptrtoint to be a `sub`, this arm requires
        # EVERY use to be an `icmp eq`/`ne`, and it rejects the empty use set.
        # Pinned by gate (O4) and gate (O2) of
        # `test/test_foz5_confined_bounds.jl`.
        #
        # Proposer A argued for placing jbko FIRST so that a
        # `.data`-base coercion whose uses are all `icmp eq/ne` would be admitted
        # rather than hitting 583s's cluster fail-loud; that widening has NO
        # corpus witness today, and a destructive probe showed that perturbing
        # `_memdata_root` breaks 583s's L58 cluster. If such a witness ever
        # appears it is a one-line ordering change (move this block above the
        # 583s block and drop the `_memdata_root` pin).
        #
        # `LLVMPtrToInt`-only, exactly as 583s is: an `inttoptr` of an
        # identity-compared address IS the forbidden escape and falls through to
        # the generic fail-loud below. Inside the `&& ptr_cells` block ⇒ the
        # circuit path is byte-identical (no arm at all when the gate is off).
        #
        # The entry condition is a DISJUNCTION so that two near-miss classes get
        # a jbko-named diagnostic rather than the generic "not a type tag"
        # message: a certified source with a bad USE, and a bad SOURCE whose
        # uses are the admissible identity shape. It does NOT cover every
        # near-miss (a8nw review D2): the `src isa LLVM.Instruction` CONJUNCT
        # means a ptr-ARGUMENT source still falls through to the generic
        # Bennett-iwo9 reject below, never reaching `_jbko_src_kind_name`'s
        # "a function argument" branch (a8nw probe P14; Bennett-vckk).
        if opc == LLVM.API.LLVMPtrToInt && src isa LLVM.Instruction &&
           _memdata_root(src) === nothing && haskey(names, src.ref) &&
           (_jbko_cell_ptr_src_kind(src) !== :none ||
            _jbko_identity_use_violation(inst) === nothing)
            srt = LLVM.value_type(src)
            drt = LLVM.value_type(inst)
            src_w = srt isa LLVM.PointerType ? 64 : _iwidth(src)
            dst_w = drt isa LLVM.PointerType ? 64 : _iwidth(inst)
            # WIDTH FIRST, SOURCE-CERTIFICATION SECOND: this check runs before
            # the (P2) `_jbko_cell_ptr_src_kind` reject below, so it also fires
            # for sources the arm would go on to REJECT as uncertified. The
            # message must therefore NOT assert that the pointer is in-model /
            # certified — nothing has established that yet — and states only the
            # width fact it has (a8nw review D5). Gate (L) of
            # `test_jbko_ptr_identity_icmp.jl` pins the substrings
            # "Bennett-jbko" and "NON-64-bit"; keep both on any reword.
            (src_w == 64 && dst_w == 64) || _ir_error(inst,
                "ptrtoint at a NON-64-bit width " *
                "(src=$(src_w) dst=$(dst_w)) under ptr_cells — genuine pointer " *
                "arithmetic, not a cell identity (Bennett-jbko / CW-D). A " *
                "pointer is ONE Int64 VM cell (ADR 0018 §A); only the 64-bit " *
                "coercion confined to an equality test is modelled, because a " *
                "narrower cast truncates the cell value (CLAUDE.md §1).")
            _jbko_cell_ptr_src_kind(src) === :none && _ir_error(inst,
                "ptrtoint under ptr_cells whose source is NOT a CERTIFIED " *
                "cell-valued pointer SSA (Bennett-jbko / CW-D). The source is " *
                "$(_jbko_src_kind_name(src)); only an `extractvalue` of a " *
                "StructType pointer field or a `load` of a pointer (addrspace " *
                "0) is certified to be stamped at width 64. In particular a " *
                "pointer-typed `phi`/`select` carries the Bennett-cc0 M2b " *
                "WIDTH-0 SENTINEL — its routing lives in `ptr_provenance` at " *
                "LOWERING time, not as a value — so coercing one would read a " *
                "cell that was NEVER MATERIALISED (a SILENT miscompile). " *
                "Rejected to fail fast (CLAUDE.md §1).")
            viol = _jbko_identity_use_violation(inst)
            viol === nothing || _ir_error(inst,
                "ptrtoint under ptr_cells whose result is NOT confined to a " *
                "pointer-IDENTITY test (Bennett-jbko / CW-D) — found $(viol). " *
                "EVERY use must be an `icmp eq`/`icmp ne` against an in-model " *
                "SSA value or the zero cell (null, Bennett-beaw). An ORDERING " *
                "compare, arithmetic, a store, a ret, an inttoptr, or a " *
                "comparison against a non-zero literal address would make the " *
                "result depend on the BVM arena LAYOUT rather than on a " *
                "source-level property. Ordering in particular is the " *
                "Bennett-8g7m / U80 address-MAGNITUDE rule, whose guard is " *
                "TYPE-based — this use gate is precisely what stops a coercion " *
                "from laundering an ordering compare around it (CLAUDE.md §1).")
            return IRBinOp(dest, :or, _operand(src, names), iconst(0), 64)
        end
        _ir_error(inst,
            "$(opname) under ptr_cells whose source is NOT a recognised Julia " *
            "type-tag value (Bennett-iwo9 / CW-D3 Lever 1). Only the type-tag " *
            "round-trip `load @\"+Type#N\" → ptrtoint → inttoptr` is modelled — " *
            "a genuine pointer↔integer round-trip (e.g. casting a real arena " *
            "pointer, or `ptrtoint ptr→i32`) would expose ARENA_BASE-relative " *
            "addresses to integer arithmetic and is rejected to fail fast " *
            "(CLAUDE.md §1).")
    end

    # branch
    if opc == LLVM.API.LLVMBr && inst isa LLVM.BrInst
        succs = LLVM.successors(inst)
        if LLVM.isconditional(inst)
            return IRBranch(_operand(LLVM.condition(inst), names),
                            Symbol(LLVM.name(succs[1])),
                            Symbol(LLVM.name(succs[2])))
        else
            return IRBranch(nothing, Symbol(LLVM.name(succs[1])), nothing)
        end
    end

    # ret
    if opc == LLVM.API.LLVMRet
        ops = LLVM.operands(inst)
        # BVM ADR 0020 D3 (CW-C2 chunk B): under the C-track `ptr_cells` gate, a
        # `ret ptr %p` returns a pointer VALUE that is one Int64 VM cell (ADR
        # 0018 §A) — width 64. The function-level return-WIDTH derivation in
        # `module_walk.jl` already maps the `ptr` return type to `ret_width = 64`;
        # this handles the matching TERMINATOR (`IRRet`'s `width`), whose operand
        # `%p` is a ptr value with no scalar `_type_width`. Gate defaults false,
        # so the Julia paths keep the byte-identical `_iwidth(ops[1])` behaviour
        # below. (`ret void` carries no operand and is NOT handled here — it is
        # chunk C / D5, see the return-width note in module_walk.jl.)
        if ptr_cells && !isempty(ops) &&
           LLVM.value_type(ops[1]) isa LLVM.PointerType
            # Bennett-beaw / CW-D: thread `ptr_cells` so a `ret ptr null`
            # operand (ConstantPointerNull) lowers to the zero cell iconst(0)
            # rather than the U80 fail-loud (the cell model: null = address 0).
            return IRRet(_operand(ops[1], names; ptr_cells=true), 64)
        end
        # BVM ADR 0020 D5b (CW-C2 chunk C): `ret void` under the C-track gate.
        # A void return carries NO operand (`isempty(ops)`) and NO width. The
        # value-bearing `IRRet(op, w)` requires `op::IROperand` + `width >= 1`,
        # so void is the dedicated `IRRet()` void FORM (`op === nothing`,
        # `width == 0`) — a terminator (so the block-builder's no-terminator
        # AssertionError never fires), but one BVM maps to
        # `EndInstruction(routine, Symbol[])` (empty returns) and
        # `_declared_returns` ⇒ `Symbol[]` (the C void-callee shape: empty
        # `CallEnter.targets`). The function-level `ret_width = 0` /
        # `ret_elem_widths = Int[]` derivation (module_walk.jl, void arm) is the
        # matching half. Gate-off: `ret void`'s function-level VoidType
        # derivation still hits the U81 wall UPSTREAM (module_walk.jl), so this
        # arm is never reached for the Julia paths; the guard is the gate.
        if ptr_cells && isempty(ops)
            return IRRet()
        end
        return IRRet(_operand(ops[1], names), _iwidth(ops[1]))
    end

    # extractvalue — select one element from an aggregate.
    # Bennett-tu6i / U10: homogeneous ArrayType aggregates (scalar element).
    # Bennett-6bu3: StructType aggregates ({ptr,ptr} GenericMemoryRef bodies,
    # mixed-width integer tuples) are now supported via per-field widths — see
    # `_struct_field_widths`. Fields are restricted to fixed-width integers
    # ({8,16,32,64}) or (under ptr_cells) pointers; i1 (`{i64,i1}` overflow/
    # cmpxchg), float, nested-struct, vector, and array fields stay FAIL-LOUD
    # there. Anything that is neither Array nor Struct (vector/scalar) still
    # falls to the final loud reject below.
    if opc == LLVM.API.LLVMExtractValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        idx_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = Int(unsafe_load(idx_ptr))  # 0-based
        # Bennett-lbot / CW-D (ADR 0017): an extractvalue whose aggregate is an
        # overflow-arith intrinsic call (`llvm.{smul,umul,sadd,uadd}.with.overflow`)
        # is FUSED into a scalar IRInst, re-deriving the value from the CALL's
        # operands — the `{iN,i1}` aggregate is never modeled (its i1 field would
        # trip the 6bu3 StructType i1-field reject via `_struct_field_widths`
        # below). The producing call emits nothing (Spot 1, CALL arm). Placed
        # BEFORE the StructType/ArrayType dispatch so the aggregate type is never
        # inspected. ptr_cells-gated ⇒ byte-identical when off.
        if ptr_cells && agg_val isa LLVM.Instruction &&
           LLVM.opcode(agg_val) == LLVM.API.LLVMCall
            cn = _heap_callee_name(agg_val)   # heap.jl: guards opcode==Call
            if startswith(cn, "llvm.smul.with.overflow.") ||
               startswith(cn, "llvm.umul.with.overflow.") ||
               startswith(cn, "llvm.sadd.with.overflow.") ||
               startswith(cn, "llvm.uadd.with.overflow.")
                return _fuse_overflow_extractvalue(agg_val, cn, idx, dest, inst, names, counter)
            end
        end
        agg_type = LLVM.value_type(agg_val)
        if agg_type isa LLVM.ArrayType
            ew = LLVM.width(LLVM.eltype(agg_type))
            ne = LLVM.length(agg_type)
            return IRExtractValue(dest, _operand(agg_val, names), idx, ew, ne)
        elseif agg_type isa LLVM.StructType
            fw = _struct_field_widths(agg_type, inst, ptr_cells)
            0 <= idx < length(fw) || _ir_error(inst,
                "extractvalue index $idx out of range for StructType $(string(agg_type)) " *
                "with $(length(fw)) fields. (Bennett-6bu3)")
            return IRExtractValue(dest, _operand(agg_val, names), idx,
                                  0, length(fw), fw)
        else
            _ir_error(inst,
                "extractvalue on $(string(agg_type)) is not supported; only " *
                "homogeneous ArrayType and (Bennett-6bu3) fixed-width " *
                "StructType aggregates are.")
        end
    end

    # insertvalue — same Array/Struct support as extractvalue.
    if opc == LLVM.API.LLVMInsertValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        elem_val = ops[2]
        idxs_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = Int(unsafe_wrap(Array, idxs_ptr, 1)[1])
        agg_type = LLVM.value_type(inst)
        if agg_type isa LLVM.ArrayType
            ew = LLVM.width(LLVM.eltype(agg_type))
            ne = LLVM.length(agg_type)
            return IRInsertValue(dest, _operand(agg_val, names),
                                 _operand(elem_val, names), idx, ew, ne)
        elseif agg_type isa LLVM.StructType
            fw = _struct_field_widths(agg_type, inst, ptr_cells)
            0 <= idx < length(fw) || _ir_error(inst,
                "insertvalue index $idx out of range for StructType $(string(agg_type)) " *
                "with $(length(fw)) fields. (Bennett-6bu3)")
            # Pass `ptr_cells` to `_operand` for the INSERTED value so a
            # `ptr null` field lowers to the zero cell (iconst(0)) per Bennett-beaw.
            return IRInsertValue(dest, _operand(agg_val, names),
                                 _operand(elem_val, names; ptr_cells=ptr_cells),
                                 idx, 0, length(fw), fw)
        else
            _ir_error(inst,
                "insertvalue on $(string(agg_type)) is not supported; only " *
                "homogeneous ArrayType and (Bennett-6bu3) fixed-width " *
                "StructType aggregates are.")
        end
    end

    # unreachable — dead code
    if opc == LLVM.API.LLVMUnreachable
        return IRBranch(nothing, :__unreachable__, nothing)
    end

    # Bennett-4eu: indirectbr is a Bennett hard stop, like atomicrmw /
    # invoke / landingpad. The static-CFG model that Bennett's phi
    # resolution and loop unrolling depend on requires block targets
    # known at compile time. `indirectbr` defers target resolution to
    # runtime via a block-address pointer — incompatible with Bennett's
    # discipline. A future implementation could lower the *constant*
    # special case (computed goto whose address is a phi/select over
    # blockaddress(@f, %bb) constants) by tracking block-address IDs
    # through pointer ops and emitting cascaded conditional branches,
    # but that's a substantial workstream and no Julia / C / Rust
    # idiom Bennett currently targets emits indirectbr (Julia never;
    # `goto *ptr` in C is a GCC extension uncommon in numerical code;
    # Rust never). Fail loud here rather than the generic
    # unsupported-opcode error so the user gets actionable context.
    if opc == LLVM.API.LLVMIndirectBr
        _ir_error(inst,
            "indirectbr (computed goto) is not supported. Bennett's " *
            "static-CFG model requires compile-time-known branch " *
            "targets — phi resolution, loop unrolling, and the Bennett " *
            "construction itself depend on it. If you reached this " *
            "from C `goto *ptr` or similar, restructure the source as " *
            "a switch over an explicit integer dispatch index. " *
            "(Bennett-4eu hard stop)")
    end

    # call instructions: handle known LLVM intrinsics, skip the rest
    if opc == LLVM.API.LLVMCall
        ops = LLVM.operands(inst)
        n_ops = length(ops)
        if n_ops >= 1
            cname = try
                LLVM.name(ops[n_ops])
            catch e
                e isa InterruptException && rethrow()
                ""
            end
            # Bennett-tzrs / U41 first cut: dispatch the LLVM-intrinsic
            # prefix block to `_handle_intrinsic` (helper above). Returns
            # nothing if no intrinsic matched; we then fall through to the
            # registered-callee path.
            handled = _handle_intrinsic(cname, inst, names, counter, dest, ops, globals;
                                        synth_ptr_provenance=synth_ptr_provenance,
                                        synth_ptr_allocas=synth_ptr_allocas,
                                        ptr_cells=ptr_cells)
            handled === nothing || return handled
        end
        # Known Julia function calls → IRCall for gate-level inlining
        if n_ops >= 1
            callee = _lookup_callee(cname)
            if callee !== nothing
                if ptr_cells
                    return _emit_cell_call(inst, ops, n_ops, names, cname, dest, callee)
                end
                # gate-inlining ABI (circuit path, ptr_cells=false): integer args
                # ONLY — pointers (pgcstack, by-ref aggregates) are skipped because
                # `lower_call!` re-extracts the callee body and inlines it. Byte-
                # identical to pre-xrd6 (the gate-count regression baselines pin it).
                #
                # Operands: first n_ops-1 are arguments, last is the callee
                # Skip pgcstack arg (first operand in swiftcc)
                call_args = IROperand[]
                call_widths = Int[]
                for i in 1:(n_ops - 1)
                    op = ops[i]
                    ot = LLVM.value_type(op)
                    ot isa LLVM.IntegerType || continue  # skip ptr args (pgcstack)
                    push!(call_args, _operand(op, names))
                    push!(call_widths, LLVM.width(ot))
                end
                ret_w = _iwidth(inst)
                return IRCall(dest, callee, call_args, call_widths, ret_w)
            end
        end

        # Bennett-40ys: an INSTANCE-LESS callee (closure / functor) registered
        # by NAME. `_lookup_callee` cannot hold it — `_known_callees` is
        # `Dict{String,Function}` and there is no `Function` value — so it is
        # resolved from `_known_callee_names` here and emitted through the SAME
        # cell-ABI helper as a registered `Function` callee, carrying the BARE
        # canonical Symbol instead of the drift-prone mangled `j_<name>_<NNN>`
        # (which BennettVM's `_vm_dispatch_name` cannot bind to the set's table
        # key). Must sit BEFORE the ADR-0020-D5 miss arm below, which would
        # otherwise emit exactly that mangled name.
        #
        # `ptr_cells=false` deliberately gets NO hook: an instance-less callee
        # cannot be gate-inlined, because `lower_call!` re-extracts the callee
        # body from a `Function` value that does not exist. It falls through to
        # the U15 fail-loud below, which names the situation explicitly.
        if ptr_cells && n_ops >= 1
            cn = _lookup_callee_name(cname)
            cn === nothing ||
                return _emit_cell_call(inst, ops, n_ops, names, cname, dest, cn)
        end

        # BVM ADR 0020 D5 (CW-C2 chunk C): call emission on a `_lookup_callee`
        # MISS, under the C-track `ptr_cells` gate. A `.ll` call whose callee is
        # not a registered Julia `Function` is, in the closed-world C model,
        # either a libc heap intrinsic or an in-module `define`d function — both
        # carried to BVM as an `IRCall` with a `Symbol` callee (the name-only
        # form; BVM resolves it: `_HEAP_DISPATCH` for the libc whitelist, the
        # guard-5 function table for an in-module callee). The callee VALUE is
        # the LAST operand (`ops[n_ops]`); it is an `LLVM.Function`. NOTE
        # (nd45 review nit 2): the code deliberately does NOT branch on
        # `isdeclaration` — declarations and in-module bodies both emit the
        # same Symbol-callee IRCall, and BVM disambiguates by name. A
        # non-whitelisted EXTERNAL (e.g. printf) is therefore NOT rejected at
        # U15 under gate-ON; it flows to BVM and rejects at the SoftCall
        # allowlist (still fail-loud, different site). Gate-off (the Julia
        # paths) this whole block is
        # skipped — a `_lookup_callee` miss falls straight through to the benign-
        # prefix allowlist / U15 fail-loud below, byte-identically.
        if ptr_cells && n_ops >= 1
            callee_val = ops[n_ops]
            if callee_val isa LLVM.Function
                # Bennett-zf5v / CW-D2: GC-rooting bookkeeping intrinsics. At
                # optimize=false the closed-world producer's bodies wall here on
                # `llvm.julia.gc_preserve_begin` (return type `token`) — the
                # ptr_cells C-call arm's TokenType reject (~below). These two
                # intrinsics carry NO value semantics in the deterministic,
                # single-threaded, history-reversible VM cell model: they only
                # extend GC roots for the live preserved pointers between
                # _begin and _end. The preserved-pointer args live independently
                # in their own SSA values (consumed by the real ops in between);
                # the only thing _begin PRODUCES is the rooting `token`, which is
                # consumed SOLELY by gc_preserve_end (also dropped) — so dropping
                # both leaves NO dangling SSA reference. Placed at the TOP of the
                # arm (BEFORE the variadic-arg loop AND the return-type check)
                # because gc_preserve_begin is variadic (`call token (...)`): a
                # lower placement would hit the arg-carry / TokenType error
                # first. Exact-name-scoped (Rule 1): any OTHER token-returning
                # call still walls at the TokenType reject below.
                if cname == "llvm.julia.gc_preserve_begin" ||
                   cname == "llvm.julia.gc_preserve_end"
                    return nothing
                end
                # CW-D2 / 416r.12: julia.write_barrier is GC card-marking with NO
                # VM value semantics (void, dest auto-named + never consumed, like
                # gc_preserve/safepoint). Drop BEFORE the generic C-call void arm
                # (which would emit a Symbol IRCall BVM has no home for). The
                # benign_prefixes list is UNREACHABLE for Function callees under
                # ptr_cells, so the drop must go here. Exact-name-scoped (Rule 1).
                if cname == "julia.write_barrier"
                    return nothing
                end
                # Bennett-r92o / CW-D3 Lever 2 (consensus decision 4): the Julia
                # typed-GC allocation `julia.gc_alloc_obj`. Un-drop it under the
                # closed-world `ptr_cells` gate, modelling it as a Symbol-callee
                # IRCall (Bennett-k3ej) the BennettVM arena floor (Lever 3,
                # ADR 0021 D3) ingests as a bump alloc. Placed at the TOP of this
                # arm — BEFORE the generic C-call arg loop — for two reasons:
                #   (1) The generic loop carries the `task` pointer arg
                #       (`ops[1]`), but `task` is a %pgcstack GEP with NO VM
                #       meaning and MUST be dropped (decision 4). We want
                #       exactly [size, tag], not [task, size, tag].
                #   (2) The generic loop would set the callee to the full dotted
                #       name `Symbol("julia.gc_alloc_obj")`; BennettVM dispatches
                #       on the canonical `:gc_alloc_obj` (`_HEAP_DISPATCH`).
                # LLVM operand layout (verified empirically): for
                # `call ptr @julia.gc_alloc_obj(ptr %task, i64 %size, ptr %tag)`,
                # `ops = [task, size, tag, callee]` (callee is the LAST operand,
                # matching the `cname = LLVM.name(ops[n_ops])` convention above).
                # So 3 args ⇔ `n_ops == 4`. FAIL LOUD (CLAUDE.md §1) on any other
                # arity — gc_alloc_obj's signature is fixed at (task, size, tag).
                # Gate-off (ptr_cells=false): this whole arm is skipped, so
                # gc_alloc_obj falls through to the broad `julia.gc_` benign drop
                # below, byte-identically to pre-r92o.
                if cname == "julia.gc_alloc_obj"
                    n_ops == 4 || _ir_error(inst,
                        "julia.gc_alloc_obj expected 3 args (task, size, tag) " *
                        "⇒ n_ops == 4 (callee is the last operand), got " *
                        "n_ops == $(n_ops). The Julia typed-GC alloc signature " *
                        "is fixed; an unexpected arity is not modelled " *
                        "(Bennett-r92o / CW-D3 Lever 2)")
                    # Drop ops[1] (task / %pgcstack GEP). Carry [size, tag] as the
                    # two Int64 VM cells; BennettVM ignores the tag's value
                    # (ADR 0021 D3 floor: tag stored but structurally unread).
                    size_op = _operand(ops[2], names)
                    tag_op = _operand(ops[3], names)
                    return IRCall(dest, :gc_alloc_obj,
                                  IROperand[size_op, tag_op], Int[64, 64], 64)
                end
                # Bennett-lbot / CW-D (ADR 0017): overflow-arith intrinsics
                # (`llvm.{smul,umul,sadd,uadd}.with.overflow.iN`, result
                # `{iN,i1}`). The `{iN,i1}` aggregate is NEVER modeled — an i1
                # struct field hits the 6bu3 i1-field reject on BOTH repos. The
                # two `extractvalue`s re-derive the scalars (wrapped product/sum
                # + overflow bit) DIRECTLY from THIS call's operands (fused at the
                # extractvalue handler, `_fuse_overflow_extractvalue`). So the
                # call itself emits NOTHING: its `dest` is bound to no IRInst and
                # its ref is consumed ONLY by those two extractvalues (any OTHER
                # consumer would fail loud at `_operand` — no dest binding). Placed
                # BEFORE the generic C-call arm to pre-empt the D5 `{iN,i1}`
                # return-type reject below. Auto-gated (inside the `ptr_cells` arm)
                # ⇒ byte-identical when off. `return nothing` skips the inst
                # (module_walk.jl `ir_inst === nothing && continue`).
                if startswith(cname, "llvm.smul.with.overflow.") ||
                   startswith(cname, "llvm.umul.with.overflow.") ||
                   startswith(cname, "llvm.sadd.with.overflow.") ||
                   startswith(cname, "llvm.uadd.with.overflow.")
                    return nothing
                end
                # A C `ptr` arg/return is one Int64 VM cell (ADR 0018 §A): every
                # operand (integer OR pointer) is carried at the cell width — a
                # ptr arg as 64, an integer arg at its own width. The C closed-
                # world model has no synthetic frame arg; the shared helper's
                # swiftself skip is therefore a no-op here (Bennett-xrd6, Rule 12 —
                # the carry loop is now shared with the registered-callee branch).
                c_args, c_widths = _cell_call_args(inst, ops, n_ops, names)
                rt = LLVM.value_type(inst)
                cn = Symbol(cname)
                if rt isa LLVM.VoidType
                    # D5b void CALL (`call void @free` / `@ht_put`): IRCall.dest
                    # is mandatory (`::Symbol`) and `ret_width >= 1`, so a void
                    # call carries the auto-named never-read `dest` (the naming
                    # pass already assigned one — line ~207) plus a `ret_width=64`
                    # SENTINEL. The dest is NEVER consumed: BVM routes a void
                    # callee to `IntrinsicFree` (takes no dest) or guard-5 with
                    # `isempty(fe.returns)` ⇒ EMPTY targets, so neither the dest
                    # nor the sentinel width is read. 64 (not a smaller value) so
                    # the IR-level invariant `ret_width == cell-width` holds for
                    # every C call, void or not — a uniform shape, no special 0.
                    return IRCall(dest, cn, c_args, c_widths, 64)
                elseif rt isa LLVM.IntegerType
                    return IRCall(dest, cn, c_args, c_widths, LLVM.width(rt))
                elseif rt isa LLVM.PointerType
                    # Pointer RETURN (`malloc` / `ht_new`) = 64-bit cell.
                    return IRCall(dest, cn, c_args, c_widths, 64)
                else
                    _ir_error(inst,
                        "C call to '$(cname)' has unsupported return type " *
                        "$(rt) under ptr_cells; only void, integer, and pointer " *
                        "(cell) returns are modelled (BVM ADR 0020 D5 / chunk C)")
                end
            end
        end

        # Bennett-5oyt / U15: falling through here means no intrinsic
        # handler matched and no callee is registered. Without this guard
        # the instruction was silently dropped, leaving its dest SSA
        # undefined and later references crashing with "Undefined SSA
        # variable" far from the root cause. Explicit allowlist of benign
        # LLVM intrinsics (memory-range annotations, optimizer hints, debug
        # info, noalias scope decls) that are correctness-neutral to drop;
        # everything else — including inline assembly — errors loud.
        benign_prefixes = (
            "llvm.lifetime.",
            "llvm.assume",
            "llvm.dbg.",
            "llvm.experimental.noalias.scope.decl",
            "llvm.invariant.start",
            "llvm.invariant.end",
            "llvm.sideeffect",
            # llvm.memset is now handled explicitly by `_handle_memset_arm`
            # above (Bennett-9nwt). The c=0 case takes a fast-path silent
            # drop that matches the previous benign-list behaviour for
            # Julia GC-frame zeroing; c≠0 cases lower to byte-granular
            # IRStore-of-ConstOperand. NOT in this list anymore.
            # `llvm.trap` is Julia's unreachable-code marker (produced by
            # type-conservative codegen for branches the compiler can't
            # prove dead). Same unreachability argument as `j_throw_*`:
            # silent drop matches pre-fix behaviour; reachable traps on
            # valid input would be a compilation bug upstream.
            "llvm.trap",
            "llvm.debugtrap",
            # Julia runtime throw helpers. For pure-bit-op functions on
            # UInt64 (the soft-float kernels) these are unreachable dead
            # code that Julia's type-conservative codegen emits anyway.
            # Silent drop matches pre-fix behaviour; see U15 note: any
            # function whose throw path IS reachable on valid input would
            # silently produce garbage, which is the same gap as before.
            "j_throw_",
            "ijl_throw",
            "jl_throw",
            "ijl_bounds_error",
            "jl_bounds_error",
            # Julia meta-ops (GC safepoint, pointer_from_objref, etc.).
            "julia.safepoint",
            "julia.gc_",
            "julia.pointer_from_objref",
            "julia.push_gc_frame",
            "julia.pop_gc_frame",
            "julia.get_gc_frame_slot",
        )
        if any(p -> startswith(cname, p), benign_prefixes)
            return nothing
        end
        # Inline asm: the callee operand is not a named function value.
        is_inline_asm = n_ops == 0 || LLVM.API.LLVMIsAInlineAsm(ops[n_ops]) != C_NULL
        is_inline_asm && _ir_error(inst,
            "inline-asm call is not supported (Bennett-5oyt / U15)")
        # Unregistered callee or unrecognised intrinsic. Bennett-40ys: if the
        # callee IS a registered instance-less callable, say so — the failure is
        # then a MODE mismatch (gate-inlining vs the VM cell ABI), not a missing
        # registration, and "call register_callee!" would be actively misleading
        # advice for a callable that has no `Function` value to register.
        if _lookup_callee_name(cname) !== nothing
            _ir_error(inst,
                "call to '$(cname)' resolves to a registered INSTANCE-LESS callee " *
                "(closure / functor) but ptr_cells=false. Instance-less callables " *
                "are modelled only under ptr_cells=true (the BennettVM cell ABI); " *
                "they cannot be gate-inlined on the circuit path, because " *
                "`lower_call!` re-extracts the callee body from a `Function` value " *
                "that does not exist for them (Bennett-40ys / Bennett-5oyt / U15)")
        end
        _ir_error(inst,
            "call to '$(cname)' has no registered callee handler or " *
            "intrinsic pattern; register via `register_callee!` or " *
            "extend the LLVMCall arm in ir_extract.jl " *
            "(Bennett-5oyt / U15)")
    end

    # GEP with constant or variable offset
    if opc == LLVM.API.LLVMGetElementPtr
        ops = LLVM.operands(inst)
        base = ops[1]
        # Case A: base is a local SSA value that we've already named
        if haskey(names, base.ref) && length(ops) == 2
            if ops[2] isa LLVM.ConstantInt
                # Constant-index GEP → IRPtrOffset (wire selection from flat array).
                # Bennett-vz5n / U12: `IRPtrOffset.offset_bytes` is consumed at
                # `lower.jl:1691` as `bit_offset = offset_bytes * 8`. The raw
                # GEP index must be scaled by the source element's byte stride
                # before being stored — for `gep i32, ptr %p, i64 1` the raw
                # index is 1 but the actual byte offset is 4. Reading
                # LLVMGetGEPSourceElementType and multiplying by `width÷8`
                # keeps the consumer semantics (`offset_bytes * 8 == bit_offset`)
                # correct for every integer stride.
                # Non-integer source types (struct/array/float/vector) fall
                # through to the pre-existing raw-index behaviour — their
                # correctness gap is tracked separately under U16
                # (multi-index struct GEPs). For integer strides the fix
                # here is unconditional; other paths are unchanged.
                raw_idx = _const_int_as_int(ops[2])
                src_ty_ref_const = LLVM.API.LLVMGetGEPSourceElementType(inst)
                src_type_const = LLVM.LLVMType(src_ty_ref_const)
                # `offset` is the byte offset (circuit-backend semantics);
                # `elem_bits` is the source element bit width threaded into the
                # additive IRPtrOffset.elem_width field so the cell-addressed
                # BennettVM can recover the element index (Bennett-xv0u /
                # bennettvm-b5x). For the integer branch it is the true element
                # width; for the legacy non-integer branch (U16 out of scope)
                # offset is the raw index, so 8 is its raw-index unit (1 byte).
                offset, elem_bits = if src_type_const isa LLVM.IntegerType
                    stride_bytes = LLVM.width(src_type_const) ÷ 8
                    stride_bytes >= 1 || _ir_error(inst,
                        "constant-index GEP with sub-byte source element " *
                        "width $(LLVM.width(src_type_const)) bits not " *
                        "supported (Bennett-vz5n / U12)")
                    (raw_idx * stride_bytes, Int(LLVM.width(src_type_const)))
                else
                    # Struct / array / float / vector base: legacy raw-index
                    # behaviour. Silent-pass, tracked in U16. elem_width=8 is
                    # the legacy raw-index unit (offset is the raw index, U16
                    # out of scope — BennettVM only receives the integer-source
                    # `mem=:vm` GEPs, never this branch).
                    (raw_idx, 8)
                end
                return IRPtrOffset(dest, ssa(names[base.ref]), offset, elem_bits)
            else
                # Variable-index GEP → IRVarGEP (MUX-tree selection at lowering time)
                # Bennett-plb7 / U13: fail loud when the source element isn't
                # an integer. The old `? LLVM.width : 8` default silently turned
                # a `gep double, ptr %p, i64 %i` (stride 64) into an
                # `elem_width = 8` GEP, selecting bit 2 instead of double 2.
                idx_op = _operand(ops[2], names)
                src_ty_ref = LLVM.API.LLVMGetGEPSourceElementType(inst)
                src_type = LLVM.LLVMType(src_ty_ref)
                src_type isa LLVM.IntegerType || _ir_error(inst,
                    "variable-index getelementptr with non-integer source " *
                    "element type $(src_type) not supported; cannot infer " *
                    "a bit-exact elem_width (Bennett-plb7 / U13)")
                ew = LLVM.width(src_type)
                return IRVarGEP(dest, ssa(names[base.ref]), idx_op, ew)
            end
        end
        # Case B: base is a global constant (T1c.2). Emit IRVarGEP carrying the
        # global's LLVM name as the base symbol; lower_var_gep! looks this up
        # in parsed.globals and dispatches to QROM.
        if base isa LLVM.GlobalVariable && LLVM.isconstant(base) && length(ops) == 2
            gname = Symbol(LLVM.name(base))
            src_ty_ref = LLVM.API.LLVMGetGEPSourceElementType(inst)
            src_type = LLVM.LLVMType(src_ty_ref)
            # Same guard as above (Bennett-plb7 / U13).
            src_type isa LLVM.IntegerType || _ir_error(inst,
                "getelementptr on global with non-integer source element " *
                "type $(src_type) not supported; cannot infer elem_width " *
                "(Bennett-plb7 / U13)")
            ew = LLVM.width(src_type)
            if ops[2] isa LLVM.ConstantInt
                # Compile-time index into a constant table — still synthesizable
                # as IRVarGEP with a constant-kind index.
                offset = _const_int_as_int(ops[2])
                return IRVarGEP(dest, ssa(gname), iconst(offset), ew)
            else
                idx_op = _operand(ops[2], names)
                return IRVarGEP(dest, ssa(gname), idx_op, ew)
            end
        end
        # Case C: two-index ARRAY GEP (bennettvm-416r.4 + Bennett-dzd). A
        # runtime-indexed array element access compiles to
        # `getelementptr [N x iM], ptr BASE, i64 0, i64 IDX` — base + TWO
        # indices (`length(ops) == 3`): the leading constant-0 steps over the
        # (single) array at BASE, IDX selects element IDX. This is semantically
        # IDENTICAL to the single-index `iM, ptr BASE, i64 IDX` form (Case A /
        # Case B above) once the leading 0 is stripped, so it lowers to the SAME
        # node — `IRVarGEP(dest, base_sym, idx, elem_width)` — which
        # `lower_var_gep!` (circuit) / BVM's `VarGEP` already handle for the
        # single-index shape. ONE shared arm covers BOTH bases:
        #   * a constant global array (`const uint8_t rom[8]`; name ∈ globals) —
        #     the bennettvm-416r.4 acceptance case (`rom[i & 7]`), lowered like
        #     Case B (base symbol = the global's LLVM name, resolved via
        #     `parsed.globals` downstream);
        #   * a named local (an alloca-backed C stack array `uint8_t a[8]`;
        #     `haskey(names, base.ref)`) — the Bennett-dzd closure, lowered like
        #     Case A (base symbol = the alloca's SSA name).
        #
        # FAIL LOUD (keeping the Bennett-qal5 / U16 breadcrumb) on every shape
        # this arm does NOT model: a non-integer array element (float / pointer /
        # nested `[K x [M x iN]]` array — no bit-exact elem_width), a first index
        # that is not the constant 0 (a non-plain array-base step), or > 3
        # operands (a genuine multi-dim GEP), which falls through to the U16 wall
        # below. Only fires when the GEP source element type is an ArrayType AND
        # the base is a recognised global-or-local — a two-index STRUCT GEP
        # (StructType source) is NOT an ArrayType, so it skips this arm and hits
        # the struct arm below unchanged.
        if length(ops) == 3
            src_ty_ref_arr = LLVM.API.LLVMGetGEPSourceElementType(inst)
            src_type_arr = LLVM.LLVMType(src_ty_ref_arr)
            if src_type_arr isa LLVM.ArrayType
                is_global_arr = base isa LLVM.GlobalVariable &&
                                LLVM.isconstant(base) &&
                                haskey(globals, Symbol(LLVM.name(base)))
                is_local_arr = haskey(names, base.ref)
                if is_global_arr || is_local_arr
                    elem_ty_arr = LLVM.eltype(src_type_arr)
                    elem_ty_arr isa LLVM.IntegerType || _ir_error(inst,
                        "two-index array getelementptr with non-integer array " *
                        "element type $(elem_ty_arr) is not supported; cannot " *
                        "infer a bit-exact elem_width (float / pointer / nested " *
                        "array are out of scope) (Bennett-qal5 / U16; " *
                        "bennettvm-416r.4)")
                    (ops[2] isa LLVM.ConstantInt &&
                     _const_int_as_int(ops[2]) == 0) || _ir_error(inst,
                        "two-index array getelementptr first index must be the " *
                        "constant 0 (the single-array base step); got a " *
                        "non-zero / non-constant first index (Bennett-qal5 / " *
                        "U16; bennettvm-416r.4)")
                    ew_arr = LLVM.width(elem_ty_arr)
                    base_sym_arr = is_local_arr ? names[base.ref] :
                                   Symbol(LLVM.name(base))
                    idx_op_arr = ops[3] isa LLVM.ConstantInt ?
                        iconst(_const_int_as_int(ops[3])) :
                        _operand(ops[3], names)
                    return IRVarGEP(dest, ssa(base_sym_arr), idx_op_arr, ew_arr)
                end
            end
        end
        # BVM ADR 0020 D4 (CW-C2 chunk B): two-index struct GEP under the
        # C-track `ptr_cells` gate. A C struct-field access compiles to
        # `getelementptr %struct.T, ptr %p, i32 0, i32 K` — base + TWO constant
        # indices (`length(ops) == 3`): index 0 steps over the (single) struct
        # at `%p`, index K selects member K. This lowers to
        # `IRPtrOffset(dest, base, offset_bytes, elem_width=64)` where
        # `offset_bytes` is the member's byte offset from the LLVM datalayout
        # (`LLVM.offsetof` → `LLVMOffsetOfElement`; NEVER IR-text parsing,
        # Bennett.jl Rule 5/8). `elem_width=64` is the cell width: every struct
        # member BVM addresses is a 64-bit cell (ADR 0018 §A).
        #
        # FAIL LOUD (still — the gate ADDS one accepted shape, it does not
        # weaken any reject) on every other two-index shape: first index ≠ 0,
        # > 2 indices, non-struct pointee, or a member offset not 8-byte aligned
        # (the BVM cell discipline — `offset_bytes % 8 == 0` per ADR 0018; a
        # packed/sub-cell struct fails loud rather than mis-addressing). The
        # `qal5`/U16 array-GEP case (`[N x iM], ptr %p, i64 0, i64 %i`,
        # variable index, non-struct pointee) is NOT a struct GEP and falls
        # through to the U16 wall below, gate or no gate.
        if ptr_cells && haskey(names, base.ref) && length(ops) == 3
            src_ty_ref_gep = LLVM.API.LLVMGetGEPSourceElementType(inst)
            src_type_gep = LLVM.LLVMType(src_ty_ref_gep)
            src_type_gep isa LLVM.StructType || _ir_error(inst,
                "two-index getelementptr with non-struct source element type " *
                "$(src_type_gep) is not handled under ptr_cells; only " *
                "`%struct.T, ptr %p, i32 0, i32 K` struct-member GEPs lower " *
                "to IRPtrOffset (BVM ADR 0020 D4 / chunk B; gate-off this shape " *
                "hits the Bennett-qal5 / U16 reject)")
            (ops[2] isa LLVM.ConstantInt && _const_int_as_int(ops[2]) == 0) ||
                _ir_error(inst,
                    "two-index struct getelementptr first index must be the " *
                    "constant 0 (single-struct step); got a non-zero / " *
                    "non-constant first index (BVM ADR 0020 D4 / chunk B)")
            ops[3] isa LLVM.ConstantInt || _ir_error(inst,
                "two-index struct getelementptr member index must be a " *
                "compile-time constant; a runtime member index is not a valid " *
                "struct access (BVM ADR 0020 D4 / chunk B)")
            member_k = _const_int_as_int(ops[3])
            dl_gep = LLVM.datalayout(LLVM.parent(LLVM.parent(LLVM.parent(inst))))
            offset_bytes = Int(LLVM.offsetof(dl_gep, src_type_gep, member_k))
            # CW-D4 (bennettvm-9n3y): the Julia GenericMemory HEADER — the
            # LITERAL (unnamed) `{ i64, ptr }` struct — is stamped BYTE-granular
            # (elem_width = 8) so BVM's per-GEP division rule
            # (`cell = offset_bytes ÷ (elem_width÷8)`) lands the data-ptr field
            # on byte-cell +8. Ground truth (callee_rehash!.ll:755-769,
            # BennettVM/scratchpad): the SAME field is read through TWO shapes —
            # this word-shaped `{i64,ptr}` field-1 GEP (element path) AND the
            # byte-shaped `gep i8 %m, 8` `.ptr_ptr` (fill!/memset path, runtime
            # length, live). The old 64-bit stamp mapped them to cell +1 vs
            # cell +8 — two cells for one field. Byte granularity is FORCED by
            # the already-shipped 416r.13 singleton headers (length@byte-cell 0,
            # data-ptr@byte-cell 8). A NAMED C `%struct.T` (even `{i64, ptr}`-
            # shaped) keeps the word-granular 64-bit stamp — the C tier is
            # byte-identical (see `_is_genericmemory_header_struct`).
            #
            # Bennett-bvmd (xkl wall 8): the type predicate is now the FALLBACK
            # arm of a UNION, not the whole rule. Where the pointer's allocation
            # ROOT is provable, the reservation's own bytes-per-cell scale wins
            # (`_cell_elem_width_struct_gep`), because it is the reservation —
            # not the type spelling — that fixes the cell map. This is what
            # closes the CW-D4 SPLIT that was live in the push! ROOT: `gep i8
            # %obj, 8` stamped 8 (cell +8) while this arm stamped 64 (cell +1)
            # for byte offset 8 of the SAME `julia.gc_alloc_obj` object, SIX
            # times. The union direction is load-bearing: a provenance-ONLY rule
            # would demote the 416r.13 singleton headers (base = a GLOBAL, no
            # root) to word granularity — a silent miscompile.
            ew_gep = _cell_elem_width_struct_gep(base, src_type_gep, names,
                                                 ptr_cells)
            # The cell-boundary guard is stated in the OBJECT'S OWN cells, not
            # in a hard-coded 8: a byte-tier field need not be 8-byte aligned
            # (its cell stride is 1), while a word-tier packed / sub-cell struct
            # still fails loud exactly as before (`% 8`, byte-identical).
            offset_bytes % (ew_gep ÷ 8) == 0 || _ir_error(inst,
                "two-index struct getelementptr member $(member_k) is at byte " *
                "offset $(offset_bytes), which is not $(ew_gep ÷ 8)-byte " *
                "(cell) aligned — the BVM cell discipline (ADR 0018) requires " *
                "every struct member to land on a cell boundary of the " *
                "object's own granularity; a packed / sub-cell struct is out " *
                "of scope (BVM ADR 0020 D4 / chunk B; stamp from " *
                "`_cell_elem_width_struct_gep` / `_root_scale`, Bennett-bvmd)")
            return IRPtrOffset(dest, ssa(names[base.ref]), offset_bytes, ew_gep)
        end
        # Bennett-qal5 / U16: anything that reaches here is either a
        # multi-index GEP (`length(ops) > 2`, e.g. `getelementptr
        # [N x iM], ptr %p, i64 0, i64 %i`) or a GEP whose base is
        # neither a named local SSA nor a constant global. Full support
        # needs type-walking byte-offset accumulation (via
        # `LLVMOffsetOfElement`), which is out of scope for the U-series
        # Phase 0 hardening. Fail loud so the missing handler surfaces
        # immediately instead of leaving dest SSA undefined and crashing
        # downstream with "Undefined SSA variable".
        n_idx = length(ops) - 1
        _ir_error(inst,
            "getelementptr with $(n_idx) index(es) or unsupported base " *
            "shape is not handled; supported forms are 2-op GEPs on a " *
            "local SSA value or on a constant GlobalVariable " *
            "(Bennett-qal5 / U16)")
    end

    # Load from pointer → IRLoad (CNOT-copy from wire subset)
    if opc == LLVM.API.LLVMLoad
        # Bennett-4mmt / U14: reject atomic / volatile loads. Reversible
        # circuit compilation has no semantics for ordering guarantees;
        # silently producing a plain IRLoad would erase the source
        # program's atomic contract and turn a correctness bug into a
        # perf "feature".
        #
        # Bennett-ares — CW-D2 lever 1: under the closed-world / BennettVM cell
        # model (`ptr_cells=true`) a RELAXED-consistency ordering is vacuous
        # (deterministic single-threaded reversible VM — no concurrent observer),
        # so the relaxable band {NotAtomic,Unordered,Monotonic,Acquire,Release}
        # falls through to the existing IRLoad lowering (ptr→cell width 64,
        # integer→width N — no new lowering). Strong orderings (AcquireRelease,
        # SequentiallyConsistent) and `volatile` (an I/O-effect contract, not an
        # ordering one) stay fail-loud. The else-arm (`ptr_cells=false`) is the
        # original U14 guard VERBATIM — circuit-path behaviour is byte-identical
        # (test_4mmt pins the text). The whole ordering check is gated because
        # the integer IRLoad fall-through is itself gate-independent.
        LLVM.API.LLVMGetVolatile(inst) == 0 || _ir_error(inst,
            "volatile load not supported (Bennett-4mmt / U14)")
        if ptr_cells
            _vm_relaxable_ordering(LLVM.API.LLVMGetOrdering(inst)) || _ir_error(inst,
                "atomic load not supported (Bennett-4mmt / U14): the ordering " *
                "is a strong synchronisation edge (AcquireRelease / " *
                "SequentiallyConsistent) that the BennettVM cell model cannot " *
                "honour; only the relaxable band {NotAtomic, Unordered, " *
                "Monotonic, Acquire, Release} is accepted under ptr_cells " *
                "(Bennett-ares / CW-D2 lever 1)")
        else
            LLVM.API.LLVMGetOrdering(inst) == LLVM.API.LLVMAtomicOrderingNotAtomic ||
                _ir_error(inst,
                    "atomic load not supported (Bennett-4mmt / U14)")
        end
        ops = LLVM.operands(inst)
        ptr = ops[1]

        # Bennett-land: load-escape guard. If the load source traces
        # back to an alloca tagged as carrying synthetic-address bytes
        # (via a prior memcpy from a struct-with-ptr-field global),
        # the only safe consumer pattern is to pipe the result into
        # another `llvm.memcpy.*` (i.e. continue carrying the bytes
        # forward, the Rust panic-Location ABI shape). ANY other use —
        # arithmetic, comparison, dereference, return — would
        # silently miscompile because the synthetic 64-bit address is
        # not the real allocator address of the pointee. Fail loud
        # here so the user gets a precise breadcrumb at the load
        # site rather than a garbage simulation result downstream.
        if !isempty(synth_ptr_allocas)
            load_root = _alloca_root_ref(ptr)
            if load_root !== nothing && load_root in synth_ptr_allocas
                # Walk uses; require every use to be an `llvm.memcpy.*`
                # intrinsic call. Anything else fails loud.
                all_memcpy = true
                n_uses = 0
                for use in LLVM.uses(inst)
                    n_uses += 1
                    user_inst = LLVM.user(use)
                    if user_inst isa LLVM.CallInst || (user_inst isa LLVM.Instruction &&
                                                       LLVM.opcode(user_inst) == LLVM.API.LLVMCall)
                        # Last operand of a call is the callee.
                        call_ops = LLVM.operands(user_inst)
                        callee_name = try
                            LLVM.name(call_ops[end])
                        catch e
                            e isa InterruptException && rethrow()
                            ""
                        end
                        if startswith(callee_name, "llvm.memcpy.")
                            continue
                        end
                    end
                    all_memcpy = false
                    break
                end
                if !all_memcpy || n_uses == 0
                    _ir_error(inst,
                        "load through pointer rooted at an alloca that " *
                        "received synthetic-address bytes from a " *
                        "ptr-field ConstantStruct global (via " *
                        "`llvm.memcpy.*` from a Bennett-land-materialised " *
                        "global). The synthetic address (high nibble " *
                        "0x1) is NOT the real allocator address of the " *
                        "pointee; loading these bytes back and using " *
                        "them as an integer / pointer / index would " *
                        "silently miscompile. The only safe consumer " *
                        "pattern is to pipe the load result into " *
                        "another `llvm.memcpy.*` (continue carrying " *
                        "the bytes forward — the Rust panic-Location " *
                        "ABI shape). Got $(n_uses == 0 ? "zero uses" : " " *
                        "a non-memcpy use") instead. (Bennett-land-ptrload)")
                end
            end
        end

        # Bennett-iwo9 / CW-D3 Lever 1: a `load ptr, ptr @"+Type#N"` reading a
        # Julia type-tag global. Recognise BY NAME (never the JIT address in the
        # initializer), mint/look-up a deterministic dense id for the canonical
        # type path, and lower to `IRBinOp(dest, :or, iconst(id), iconst(0), 64)`
        # — a width-64 constant identity (consensus decisions 1+3). Record `dest`
        # in `tag_ssa` so the downstream ptrtoint/inttoptr round-trip is
        # recognised as the sound type-tag pattern. ptr_cells-gated; the pointer
        # operand is a `GlobalVariable` (not a registered SSA name), so this must
        # run BEFORE the `haskey(names, ptr.ref)` block and the generic 64-bit
        # IRLoad / `return nothing` fall-throughs. The `return IRBinOp(...)` here
        # is itself the "no silent fall-through" protection: once a load is
        # recognised as a type-tag-named global it ALWAYS emits the minted
        # identity and never reaches the generic IRLoad. (`_canonical_type_path`
        # supplies the only fail-loud on this path — a malformed `+`-name lacking
        # the `#N` suffix.)
        if ptr_cells && ptr isa LLVM.GlobalVariable
            pname = LLVM.name(ptr)
            if _is_type_tag_global_name(pname)
                canon = _canonical_type_path(pname)   # fail-loud on malformed `+`-names
                id = get!(tag_ids, canon) do
                    Int64(length(tag_ids))            # dense, first-seen order
                end
                push!(tag_ssa, inst.ref)
                return IRBinOp(dest, :or, iconst(Int(id)), iconst(0), 64)
            end
            # bennettvm-416r.13 / CW-D3 Lever 2: a `load ptr, ptr @"jl_global#N"`
            # reading an empty-GenericMemory singleton-data pointer. Same LLVM
            # shape as the type-tag arm above, but the global is a DATA pointer
            # (a zeroed 16-cell header materialised into `.globals` by
            # `_extract_const_globals`), not a type identity. We emit NO IRInst
            # (drop the load) and ALIAS the load-result SSA name to the STABLE
            # GLOBAL-VARIABLE name (`pname`): a singleton is loaded MORE THAN ONCE
            # (each `load` result gets its own drifting SSA name — e.g. the vals
            # singleton yields `jl_global#23383` and `jl_global#233831`), and all
            # of them must collapse to the SINGLE canonical `.globals` key so (a)
            # pointer identity is preserved and (b) the VM binds it once via its
            # prepended `GLOBAL_BASE` `Define`. SSA guarantees defs precede uses,
            # so every downstream `IRPtrOffset`/`IRStore` operand then resolves
            # (via `_operand`) to `ssa(:jl_global#N)` = the seeded header — no
            # dangling operand. Must run BEFORE the `haskey(names, ptr.ref)` block
            # (a GlobalVariable operand is never an SSA name) and the fail-loud
            # below. (Design B D3; the "loaded twice" wrinkle is load-bearing.)
            if _is_singleton_data_global_name(pname)
                names[inst.ref] = Symbol(pname)
                return nothing
            end
        end

        if haskey(names, ptr.ref)
            rt = LLVM.value_type(inst)
            if rt isa LLVM.IntegerType
                return IRLoad(dest, ssa(names[ptr.ref]), LLVM.width(rt))
            end
            # BVM ADR 0020 D3 (CW-C2 chunk B): under the C-track `ptr_cells`
            # gate, a `load ptr` reads a pointer VALUE = one Int64 VM cell (ADR
            # 0018 §A) — model it as a 64-bit IRLoad. This admits the C
            # heap-pointer surface (`%2 = load ptr, ptr %t`). The gate defaults
            # false, so for the circuit/:heap models a non-integer load keeps the
            # pre-existing silent-skip (`return nothing`) behaviour below — the C
            # cell model never aliases those paths.
            if ptr_cells && rt isa LLVM.PointerType
                return IRLoad(dest, ssa(names[ptr.ref]), 64)
            end
        end
        # bennettvm-416r.13 (Design A D2, adopted): fail loud on an UNRECOGNIZED
        # Julia JIT-global pointer load. A `ptr_cells` `load ptr, ptr
        # @GlobalVariable` whose result is a POINTER and whose global matched
        # NEITHER the `+Type#N` type-tag arm NOR the `jl_global#N` singleton arm
        # (both above return on match) reaches here. `haskey(names, ptr.ref)` is
        # false for a GlobalVariable operand, so it would otherwise fall through
        # to the silent `return nothing` below — leaving a dangling SSA operand
        # that KeyErrors at VM run time (the exact 416r.13 wall this bead clears).
        # Fail loud AT THE LOAD SITE instead (Rule 1): a future third kind of
        # interned global surfaces here, named, with the recognized kinds spelled
        # out — never as a downstream dangling operand. Scoped to a pointer-typed
        # result so a scalar `load iN, ptr @global` keeps its pre-existing skip.
        if ptr_cells && ptr isa LLVM.GlobalVariable &&
           LLVM.value_type(inst) isa LLVM.PointerType
            gname = string(LLVM.name(ptr))
            # Bennett-klgz / bennettvm-90l: determinism CLASSIFIER. If this is a
            # runtime-callee GOT stub (`@"jlplt_<callee>_<N>_got"`), demangle the
            # callee and refine the diagnostic by hash family BEFORE the generic
            # reject. This ADMITS NOTHING NEW — both families still fail loud;
            # only the message (and its named cause) differs. Anything that is
            # not a GOT stub falls straight through to the generic message below,
            # unchanged (the fdict isbits set never reaches here — its 3 ptrtoint
            # are `+Type#N` tags handled by the type-tag arm above).
            got_callee = _demangle_got_callee(gname)
            if got_callee !== nothing && got_callee in _IDENTITY_HASH_GOT_CALLEES
                _ir_error(inst,
                    "reversible determinism floor: this `Dict` key is hashed by " *
                    "OBJECT IDENTITY / allocation address via the runtime callee " *
                    "`" * got_callee * "` (GOT stub `@\"" * gname * "\"`). A " *
                    "mutable-struct key uses the default `hash` = `objectid`, " *
                    "which hashes the object's heap ADDRESS — that address is " *
                    "NON-DETERMINISTIC across replays, so the probe sequence (and " *
                    "hence the reversible history) is UNREPLAYABLE. This is the " *
                    "one genuine in-principle blocker of the reversible floor " *
                    "(ADR 0015 Decision 3 / ADR 0017 corollary), not a modeling " *
                    "gap. Use isbits keys (Int/Float/Char/isbits-struct) or " *
                    "content-hashed `String` keys instead (Bennett-klgz / " *
                    "bennettvm-90l / CLAUDE.md §1).")
            elseif got_callee !== nothing && got_callee in _CONTENT_HASH_GOT_CALLEES
                _ir_error(inst,
                    "runtime-callee GOT stub `@\"" * gname * "\"` for the " *
                    "deterministic content hash `" * got_callee * "` (the " *
                    "`String` byte hash; `Symbol` hashing is objectid-based " *
                    "and NOT in this bucket) is not yet modeled under " *
                    "ptr_cells. Unlike identity hashing, a content hash IS " *
                    "reproducible across replays and is IN SCOPE for the " *
                    "reversible floor (ADR 0015 Decision 3) — this reject is a " *
                    "MODELING GAP (runtime-callee GOT-stub modeling is future " *
                    "work), NOT a correctness/determinism floor. Once the " *
                    "extractor learns to model `jlplt_<name>_got` stubs as named " *
                    "runtime calls, `String`-key Dicts extract here (Bennett-klgz " *
                    "/ bennettvm-90l / CLAUDE.md §1).")
            end

            # ---- Bennett-3vf2 / CW-D: the DEAD-USE DROP -------------------
            # Third recognized disposition for an unrecognised JIT-global
            # pointer load — and, unlike the two arms above, NOT a name rule.
            #
            # Julia's codegen HOISTS `load ptr, ptr @jl_diverror_exception` into
            # the LIVE predecessor of a divisor-validity guard diamond whose
            # throwing arm is `unreachable`-terminated (measured on the real
            # `Base._growend!` closure: 4 sites, `%L13 %L20 %L25 %pass57`, one
            # use each — a `call void @ijl_throw(ptr %exc)` in the DEAD `%fail*`
            # arm). The Bennett-utzc pruner discards the consumer's block BODY,
            # but the hoisted load itself sits in a KEPT block and reaches here.
            #
            # So: DROP the load iff it is non-volatile, non-atomic, has >= 1 use,
            # and EVERY use's parent block is in the utzc `dead_blocks` set. The
            # soundness argument is a THEOREM ABOUT THE PRUNER, not a claim about
            # Julia's naming conventions — see `_all_uses_in_dead_blocks` in
            # `vector_vm_cfg.jl` for the proof, the φ corollary, and the coupling
            # note. Because it is name-agnostic it also covers the OTHER
            # unrecognised global kinds already present in that same function
            # (`@jl_sym#convert#N`, whose loads happen to sit inside dead blocks
            # today) with no Julia-version drift surface.
            #
            # The drop is PURE: no `IRInst`, no `.globals` entry, no SSA alias
            # (contrast the singleton arm above, which aliases BECAUSE surviving
            # instructions read the pointer as data). And it `delete!`s the
            # load's `names` entry: if the theorem were ever wrong, `_operand`
            # then fails LOUD ("unknown operand ref … the producing instruction
            # was skipped") instead of dangling into a VM-run-time KeyError —
            # exactly the failure mode bennettvm-416r.13 exists to prevent.
            # (`dest = names[inst.ref]` is read at the top of this function, so
            # the deletion cannot orphan anything already emitted.)
            #
            # PLACEMENT is deliberate: AFTER the Bennett-klgz GOT-stub
            # classifier, so the determinism-floor diagnostics keep priority (a
            # `jlplt_*_got` load with all-dead uses would be droppable by the
            # theorem, but masking a determinism-floor reject to save a dead
            # instruction is a bad trade — CLAUDE.md §1). It carves out ONLY the
            # generic reject below.
            #
            # `volatile` is currently unreachable here (the Bennett-4mmt / U14
            # guard at the top of the load handler rejects it unconditionally);
            # it is re-checked anyway because that guard's ATOMIC half WAS later
            # relaxed under `ptr_cells` by Bennett-ares, so the same could happen
            # to the volatile half. An observable I/O event is never droppable.
            # Atomic loads in the ares relaxable band DO reach here, and are
            # deliberately NOT dropped: the drop is only proven for a plain load.
            _3vf2_vol = LLVM.API.LLVMGetVolatile(inst) != 0
            _3vf2_atomic = LLVM.API.LLVMGetOrdering(inst) !=
                           LLVM.API.LLVMAtomicOrderingNotAtomic
            if !_3vf2_vol && !_3vf2_atomic &&
               _all_uses_in_dead_blocks(inst, dead_blocks)
                delete!(names, inst.ref)
                return nothing
            end

            # Not droppable — say WHY, at the load site, in the reject below.
            _3vf2_n_uses = 0
            for _ in LLVM.uses(inst)
                _3vf2_n_uses += 1
            end
            _3vf2_live_blk = _first_live_use_block(inst, dead_blocks)
            _3vf2_why = if _3vf2_vol
                " Bennett-3vf2 (dead-use drop) declined it: the load is " *
                "VOLATILE — an observable I/O event, never droppable."
            elseif _3vf2_atomic
                " Bennett-3vf2 (dead-use drop) declined it: the load is " *
                "ATOMIC. Bennett-ares lets a relaxable-band ordering through " *
                "the U14 guard under ptr_cells, but the dead-use drop is only " *
                "proven for a PLAIN load, so an atomic global load still fails " *
                "loud here."
            elseif _3vf2_n_uses == 0
                " Bennett-3vf2 (dead-use drop) declined it: the load result " *
                "has ZERO uses. A use-less unrecognised global load is not " *
                "evidence of a modelled construct — it is evidence that the " *
                "walker's picture of this function is incomplete — so it is " *
                "refused rather than swallowed (CLAUDE.md §1)."
            elseif _3vf2_live_blk !== nothing
                " Bennett-3vf2 (dead-use drop) declined it: this load's " *
                "result IS used in the LIVE block `%" * _3vf2_live_blk *
                "`. Only a load whose EVERY use lies in a provably-dead " *
                "(`unreachable`-terminated, body-pruned by Bennett-utzc) block " *
                "may be dropped — there, nothing survives to reference it. A " *
                "live use means the value is genuinely READ and dropping it " *
                "would dangle." *
                (occursin(r"^jl_[a-z_]+_exception$", gname) ?
                 " NOTE: `@\"" * gname * "\"` is one of Julia's pre-allocated " *
                 "exception singletons (a `JL_GLOBALLY_ROOTED jl_value_t *` in " *
                 "julia.h). Its load is normally consumed ONLY by an " *
                 "`ijl_throw` in an `unreachable` arm, so a LIVE use is " *
                 "unexpected: either codegen's guard-diamond idiom changed, or " *
                 "the exception OBJECT is genuinely being read (e.g. a `catch` " *
                 "handler inspecting it). The closed world does not model that " *
                 "runtime object — there is no arena cell that IS it — so this " *
                 "needs its own bead, not a wider drop rule." : "")
            else
                ""
            end
            _ir_error(inst,
                "load of an UNRECOGNIZED Julia JIT global `@\"" *
                gname * "\"` (a `constant ptr` whose load " *
                "returns a pointer) under ptr_cells. The recognized runtime-" *
                "global kinds are: (1) `+<dotted.Type>#<N>` type-tag globals " *
                "(lowered to a constant identity), and (2) `jl_global#<N>` " *
                "empty-GenericMemory singleton-data globals (modelled as a " *
                "zeroed header in `.globals`). This global matches neither, so " *
                "its load cannot be lowered; silently dropping it would leave a " *
                "dangling SSA operand that KeyErrors at VM run time. Fail loud " *
                "at the load site (bennettvm-416r.13 / CLAUDE.md §1)." *
                _3vf2_why)
        end
        return nothing  # non-integer load — skip
    end

    # switch → IRSwitch (expanded to cascaded branches in post-pass)
    # Operand layout: [condition, default_bb, case_val1, case_bb1, ...]
    if opc == LLVM.API.LLVMSwitch && inst isa LLVM.SwitchInst
        ops = LLVM.operands(inst)
        cond_val = ops[1]
        cond_op = _operand(cond_val, names)
        cond_w = _iwidth(cond_val)
        default_ref = LLVM.API.LLVMGetSwitchDefaultDest(inst)
        default_label = Symbol(unsafe_string(LLVM.API.LLVMGetBasicBlockName(default_ref)))
        n_cases = (length(ops) - 2) ÷ 2
        cases = Tuple{IROperand, Symbol}[]
        for i in 0:(n_cases - 1)
            case_val = ops[3 + 2*i]     # ConstantInt
            case_bb  = ops[4 + 2*i]     # BasicBlock
            case_int = _const_int_as_int(case_val)
            case_op = iconst(case_int)
            target_label = Symbol(LLVM.name(case_bb))
            push!(cases, (case_op, target_label))
        end
        return IRSwitch(cond_op, cond_w, default_label, cases)
    end

    # freeze: identity (removes poison/undef, no-op for reversible circuits)
    if opc == LLVM.API.LLVMFreeze
        src = LLVM.operands(inst)[1]
        w = _iwidth(src)
        return IRBinOp(dest, :add, _operand(src, names), iconst(0), w)
    end

    # fptosi/fptoui: float → int conversion via soft_fptosi / soft_fptoui.
    # Bennett-b1vp / U31: fptoui must NOT route through fptosi — the signed
    # converter sign-reinterprets in-range values that require the high bit
    # of an unsigned 64-bit integer (e.g. 1e19). Dispatch per opcode.
    if opc in (LLVM.API.LLVMFPToSI, LLVM.API.LLVMFPToUI)
        src = LLVM.operands(inst)[1]
        src_w = _iwidth(src)
        dst_w = _iwidth(inst)
        callee_name = opc == LLVM.API.LLVMFPToUI ? "soft_fptoui" : "soft_fptosi"
        callee = _lookup_callee(callee_name)
        if callee !== nothing && src_w == 64
            # Route through the signed/unsigned softfloat callee for Float64 → iN.
            call_result = IRCall(dest, callee, [_operand(src, names)], [src_w], dst_w)
            if dst_w == src_w
                return call_result
            else
                # Need to truncate the 64-bit result to the target width
                trunc_dest = dest
                call_dest = _auto_name(counter)
                return [
                    IRCall(call_dest, callee, [_operand(src, names)], [src_w], 64),
                    IRCast(dest, :trunc, ssa(call_dest), 64, dst_w),
                ]
            end
        end
        # Fallback: treat as width conversion (for non-Float64 or when callee not registered)
        return IRCast(dest, dst_w < src_w ? :trunc : (dst_w > src_w ? :zext : :trunc), _operand(src, names), src_w, dst_w)
    end

    # sitofp/uitofp: int → float conversion via soft_sitofp (actual IEEE 754 encode)
    if opc in (LLVM.API.LLVMSIToFP, LLVM.API.LLVMUIToFP)
        src = LLVM.operands(inst)[1]
        src_w = _iwidth(src)
        dst_w = _iwidth(inst)
        callee = _lookup_callee("soft_sitofp")
        if callee !== nothing && dst_w == 64
            if src_w == 64
                return IRCall(dest, callee, [_operand(src, names)], [src_w], dst_w)
            else
                # Widen source to 64-bit first, then convert
                widen_dest = _auto_name(counter)
                cast_op = opc == LLVM.API.LLVMSIToFP ? :sext : :zext
                return [
                    IRCast(widen_dest, cast_op, _operand(src, names), src_w, 64),
                    IRCall(dest, callee, [ssa(widen_dest)], [64], 64),
                ]
            end
        end
        # Fallback
        return IRCast(dest, dst_w > src_w ? :zext : (dst_w < src_w ? :trunc : :trunc), _operand(src, names), src_w, dst_w)
    end

    # fcmp: floating-point comparison. Route through soft_fcmp_* functions.
    if opc == LLVM.API.LLVMFCmp
        ops = LLVM.operands(inst)
        pred = LLVM.predicate(inst)
        op1 = _operand(ops[1], names)
        op2 = _operand(ops[2], names)
        w = _iwidth(ops[1])
        # Map LLVM FCmp predicates to soft_fcmp functions
        # LLVM predicates: OEQ=1, OGT=2, OGE=3, OLT=4, OLE=5, ONE=6, ORD=7, UNO=8, UEQ=9, UGT=10, UGE=11, ULT=12, ULE=13, UNE=14
        pred_int = Int(pred)
        if pred_int == 4  # OLT: a < b
            callee = _lookup_callee("soft_fcmp_olt")
        elseif pred_int == 1  # OEQ: a == b
            callee = _lookup_callee("soft_fcmp_oeq")
        elseif pred_int == 5  # OLE: a <= b
            callee = _lookup_callee("soft_fcmp_ole")
        elseif pred_int == 14  # UNE: a != b or NaN
            callee = _lookup_callee("soft_fcmp_une")
        elseif pred_int == 2  # OGT: a > b → olt(b, a)
            callee = _lookup_callee("soft_fcmp_olt")
            op1, op2 = op2, op1  # swap
        elseif pred_int == 3  # OGE: a >= b → ole(b, a)
            callee = _lookup_callee("soft_fcmp_ole")
            op1, op2 = op2, op1  # swap
        # Bennett-d77b / U132: 6 new direct predicates + 2 more swap-derived
        elseif pred_int == 6  # ONE: ordered not-equal
            callee = _lookup_callee("soft_fcmp_one")
        elseif pred_int == 7  # ORD: neither NaN
            callee = _lookup_callee("soft_fcmp_ord")
        elseif pred_int == 8  # UNO: at least one NaN
            callee = _lookup_callee("soft_fcmp_uno")
        elseif pred_int == 9  # UEQ: unordered equal
            callee = _lookup_callee("soft_fcmp_ueq")
        elseif pred_int == 10  # UGT: a > b unordered → ult(b, a)
            callee = _lookup_callee("soft_fcmp_ult")
            op1, op2 = op2, op1  # swap
        elseif pred_int == 11  # UGE: a >= b unordered → ule(b, a)
            callee = _lookup_callee("soft_fcmp_ule")
            op1, op2 = op2, op1  # swap
        elseif pred_int == 12  # ULT: unordered less-than
            callee = _lookup_callee("soft_fcmp_ult")
        elseif pred_int == 13  # ULE: unordered less-than-or-equal
            callee = _lookup_callee("soft_fcmp_ule")
        else
            _ir_error(inst, "unsupported fcmp predicate $pred_int")
        end
        callee === nothing && _ir_error(inst,
            "soft_fcmp callee not registered for fcmp predicate $pred_int")
        # soft_fcmp returns UInt64 (0 or 1), but fcmp result is i1.
        # Use IRCall with ret_width=1 and let lowering truncate.
        call_dest = _auto_name(counter)
        return [
            IRCall(call_dest, callee, [op1, op2], [w, w], w),
            IRCast(dest, :trunc, ssa(call_dest), w, 1),
        ]
    end

    # bitcast: reinterpret bits as different type (same width). Zero gates — wire aliasing.
    if opc == LLVM.API.LLVMBitCast
        src = LLVM.operands(inst)[1]
        src_w = _iwidth(src)
        dst_w = _iwidth(inst)
        # Same width: identity (just alias the wires). Different width shouldn't happen per LLVM spec.
        src_w == dst_w || _ir_error(inst, "bitcast width mismatch: $src_w → $dst_w")
        return IRCast(dest, :trunc, _operand(src, names), src_w, dst_w)
    end

    # fneg: floating-point negation. XOR the sign bit.
    if opc == LLVM.API.LLVMFNeg
        src = LLVM.operands(inst)[1]
        w = _iwidth(src)
        # Sign bit is bit w-1. For w=64, 1<<63 overflows Int64, so use negative literal.
        sign_bit = w == 64 ? typemin(Int64) : Int(1 << (w - 1))
        return IRBinOp(dest, :xor, _operand(src, names), iconst(sign_bit), w)
    end

    # store: `store ty val, ptr p` -> IRStore (no dest — void in LLVM).
    if opc == LLVM.API.LLVMStore
        # Bennett-4mmt / U14: reject atomic / volatile stores — same
        # reasoning as the load guard above.
        #
        # Bennett-ares — CW-D2 lever 1: under the closed-world / BennettVM cell
        # model (`ptr_cells=true`) the relaxable band {NotAtomic,Unordered,
        # Monotonic,Acquire,Release} falls through to the existing IRStore
        # lowering (ptr→cell width 64, integer→width N — no new lowering).
        # Strong orderings (AcquireRelease, SequentiallyConsistent) and
        # `volatile` stay fail-loud. The else-arm (`ptr_cells=false`) is the
        # original U14 guard VERBATIM — circuit-path behaviour is byte-identical
        # (test_4mmt pins the text). See the load guard above for the full
        # rationale; both guards are gated identically.
        LLVM.API.LLVMGetVolatile(inst) == 0 || _ir_error(inst,
            "volatile store not supported (Bennett-4mmt / U14)")
        if ptr_cells
            _vm_relaxable_ordering(LLVM.API.LLVMGetOrdering(inst)) || _ir_error(inst,
                "atomic store not supported (Bennett-4mmt / U14): the ordering " *
                "is a strong synchronisation edge (AcquireRelease / " *
                "SequentiallyConsistent) that the BennettVM cell model cannot " *
                "honour; only the relaxable band {NotAtomic, Unordered, " *
                "Monotonic, Acquire, Release} is accepted under ptr_cells " *
                "(Bennett-ares / CW-D2 lever 1)")
        else
            LLVM.API.LLVMGetOrdering(inst) == LLVM.API.LLVMAtomicOrderingNotAtomic ||
                _ir_error(inst,
                    "atomic store not supported (Bennett-4mmt / U14)")
        end
        ops = LLVM.operands(inst)
        val = ops[1]
        ptr = ops[2]
        vt = LLVM.value_type(val)
        # BVM ADR 0020 D3 (CW-C2 chunk B): under the C-track `ptr_cells` gate, a
        # `store ptr %v, ptr %p` stores a pointer VALUE that is one Int64 VM cell
        # (ADR 0018 §A) — model it as a 64-bit IRStore. This admits the C
        # heap-pointer surface (`store ptr %t, ptr %t.addr`, `store ptr %call,
        # ptr %keys`) WITHOUT touching the Julia paths: the gate defaults false,
        # so the Bennett-lgzx / U114 fail-loud below still fires byte-identically
        # for the circuit/:heap models it protects. Width is the cell width (64),
        # not `LLVM.width(vt)` (PointerType has no integer width). The store
        # target `%p` must still be a registered SSA name — same guard as below.
        if ptr_cells && vt isa LLVM.PointerType
            haskey(names, ptr.ref) || _ir_error(inst,
                "store target pointer is not a registered SSA name " *
                "(value=$(ptr)) — likely an unsupported pointer source " *
                "such as a global, ConstantExpr, or alias (Bennett-lgzx / U114).")
            # Bennett-beaw / CW-D: thread `ptr_cells` so a `store ptr null, ptr
            # %obj` field-init (ConstantPointerNull stored value) lowers to the
            # zero cell iconst(0) rather than the U80 fail-loud (null = address
            # 0, one Int64 VM cell).
            return IRStore(ssa(names[ptr.ref]),
                           _operand(val, names; ptr_cells=true), 64)
        end
        # Bennett-p06b / CW-D (xkl wall 6): under the closed-world `ptr_cells`
        # gate a WHOLE-AGGREGATE `store <S> %agg, ptr %p` (S an unpacked
        # StructType of N 64-bit fields) decomposes into the field-wise
        # sequence the extractor ALREADY admits. See the big comment block at
        # the top of this file (search `Bennett-p06b`) for the exactness /
        # determinism / reversibility argument and for why each predicate is a
        # positive whitelist rather than a type test.
        #
        # PLACEMENT: strictly BETWEEN the ADR 0020 D3 `PointerType` cell-store
        # arm above (disjoint predicate — a StructType is not a PointerType, so
        # that arm is byte-identical) and the Bennett-lgzx / U114 `IntegerType`
        # reject below (whose TEXT is untouched: this arm either returns or
        # throws before reaching it, and with `ptr_cells=false` there is no arm
        # at all). Every input that reaches this point today hits that
        # unconditional throw, so NO currently-green extraction can change
        # behaviour and the circuit path is byte-identical BY CONSTRUCTION.
        if ptr_cells && vt isa LLVM.StructType
            # (P1) The LITERAL `{i64,ptr}` Julia GenericMemory HEADER is the ONE
            # struct type the D4 GEP arm stamps BYTE-granular (elem_width 8,
            # CW-D4 / bennettvm-9n3y, forced by the shipped 416r.13 singleton
            # headers). A word-granular store would land on cells 0/1 while its
            # own field GEPs land on byte-cells 0/8. Mirroring the byte stamp is
            # a one-line widening (`ew = _is_genericmemory_header_struct(vt) ?
            # 8 : 64`) that MEASURES fine, but the missing piece is the 416r.13
            # singleton-header interaction argument, and there is NO live
            # `store {i64,ptr}` in the corpus — so Rule 1 prefers the
            # conservative loud reject. A NAMED `%struct.T = type {i64,ptr}` is
            # not a literal struct and keeps the word-granular stamp (the C-tier
            # discriminator the haiy/nd45 pins already rely on).
            _is_genericmemory_header_struct(vt) && _ir_error(inst,
                "aggregate store of the LITERAL $(string(vt)) GenericMemory " *
                "HEADER struct is not decomposable into 64-bit cells: the " *
                "two-index struct-GEP arm stamps this ONE type at BYTE " *
                "granularity (elem_width 8, CW-D4 / bennettvm-9n3y), so its " *
                "field GEPs address byte-cells 0/8 while a word-granular " *
                "store would address cells 0/1 — two cell maps for one " *
                "object. Refused rather than mirrored: there is no live " *
                "corpus witness and the 416r.13 singleton-header interaction " *
                "is unverified. A NAMED `%struct.T = type {i64, ptr}` keeps " *
                "the word-granular stamp and IS admitted. (Bennett-p06b, " *
                "predicate `_is_genericmemory_header_struct`) " *
                "Bennett-bvmd NOTE (prose-vs-predicate): under bvmd the D4 " *
                "stamp is PROVENANCE-FIRST, so for a target whose allocation " *
                "root has a provable scale the header GEP and this store would " *
                "now agree; the two-cell-maps sentence above describes the " *
                "SCALE-UNKNOWN root, where the type predicate is still the " *
                "whole rule. The refusal is retained UNCHANGED anyway — there " *
                "is still no live corpus witness and the 416r.13 " *
                "singleton-header interaction is still unverified.")
            # (P2) Field certification — REUSE the Bennett-6bu3 predicate, do
            # not re-implement it (Rule 12). p06b therefore opens NO new
            # field-shape message territory: packed / empty / i1 / float /
            # nested-struct / vector / array fields and out-of-band integer
            # widths all keep naming Bennett-6bu3.
            fw_p06b = _struct_field_widths(vt, inst, ptr_cells)
            # (P3) ONE WHOLE CELL PER FIELD, layout-derived. Offsets come from
            # `LLVM.offsetof` → `LLVMOffsetOfElement` (never IR-text parsing,
            # never `index * width` — Rule 5 / the dv1z-7wsz discipline) and are
            # COMPARED against `8k`, never assumed. Stricter than (P2) on
            # purpose: a sub-cell or padded field would need a read-modify-write
            # of the surrounding cell, which BennettVM's whole-cell MemoryStore
            # does not express. Re-checks the width itself rather than trusting
            # (P2)'s width set, so a future relaxation of `_struct_field_widths`
            # cannot silently widen this arm.
            dl_p06b = LLVM.datalayout(LLVM.parent(LLVM.parent(LLVM.parent(inst))))
            offs_p06b = Int[]
            for k in 0:(length(fw_p06b) - 1)
                off_k = Int(LLVM.offsetof(dl_p06b, vt, k))
                (fw_p06b[k + 1] == 64 && off_k == 8 * k) || _ir_error(inst,
                    "aggregate store of $(string(vt)) is not decomposable " *
                    "into whole 64-bit cells: field $k has width " *
                    "$(fw_p06b[k + 1]) bits at byte offset $(off_k) (expected " *
                    "width 64 at offset $(8 * k) — exactly one cell per " *
                    "field, fields tiling [0, $(8 * length(fw_p06b))) with no " *
                    "padding). BennettVM's MemoryStore writes a WHOLE cell, so " *
                    "a sub-cell or padded field would need a read-modify-write " *
                    "of the surrounding cell, which the cell model (ADR 0018 " *
                    "§A) does not express. (Bennett-p06b, predicate: the " *
                    "`fw[k+1] == 64 && off_k == 8k` loop above)")
                push!(offs_p06b, off_k)
            end
            # (P4a) The target must be a registered SSA name. D5: this reject is
            # REACHABLE on p06b shapes, so it must carry p06b's OWN bead name.
            # Reusing the lgzx text verbatim (as this arm first did) meant a
            # (P4a) firing on the corpus would be misattributed to the lgzx wall
            # by the three advanced wall markers, whose `!occursin("Bennett-lgzx")`
            # is a LOAD-BEARING negative — and it escaped the message-hygiene
            # sweep by construction. The lgzx cross-reference stays as CONTEXT.
            haskey(names, ptr.ref) || _ir_error(inst,
                "aggregate store target pointer is not a registered SSA name " *
                "(value=$(ptr)) — likely an unsupported pointer source such as " *
                "a global, ConstantExpr, or alias. (Bennett-p06b, predicate: " *
                "the `haskey(names, ptr.ref)` test above. The scalar store arm " *
                "words the same condition under its own bead; this reject is " *
                "reached from the AGGREGATE arm and is deliberately attributed " *
                "here, because the push! wall markers use that bead's name as a " *
                "load-bearing negative and would otherwise misreport a p06b " *
                "failure as the store-type wall.)")
            # (P4b) ... AND a CERTIFIED cell pointer. Registration is NOT
            # sufficient: `module_walk.jl` names every instruction whether or
            # not the converter emits an IRInst for it.
            tkind, tcells = _p06b_cell_ptr_target_kind(ptr, names, ptr_cells,
                                                       suppressed_refs)
            tkind === :none && _ir_error(inst,
                "aggregate store target is not a CERTIFIED cell pointer — it " *
                "is $(_p06b_target_kind_name(ptr, suppressed_refs)). Only a " *
                "`load` of a pointer whose own pointer operand is a registered " *
                "SSA name, an allocator `call` " *
                "($(join(_M4_C_ALLOCATOR_NAMES, ", "))), or an `alloca` whose " *
                "allocated type the alloca arm actually MODELS are admitted, " *
                "all in addrspace 0 and none suppressed by the module walk. " *
                "Being a registered SSA name is NOT sufficient: the naming " *
                "pass registers EVERY instruction, so decomposing into an " *
                "unmaterialised name would hand BennettVM stores into cells " *
                "nothing ever reserved. (Bennett-p06b, predicate " *
                "`_p06b_cell_ptr_target_kind`)")
            # (P4c) ... AND it must have CERTIFIED CAPACITY for all N cells.
            # Hostile-review defect D1, a SILENT MISCOMPILE: (P4b) proves an
            # IRAlloca/arena bump happens, NOT that it reserves >= N cells.
            # `tcells == -1` is the `:load` case ONLY — see the disclosure
            # below. Enforced by `_p06b_alloca_cells` / `_p06b_call_bytes`.
            #
            # HONEST DISCLOSURE FOR `:load` TARGETS (prose-vs-predicate rule —
            # D1 and D2 were both messages asserting guarantees no code
            # checked, so this paragraph states ONLY what is enforced).
            # `tcells == -1` means the capacity is NOT CERTIFIED and NOTHING
            # BELOW CHECKS IT. This is the REAL CORPUS SHAPE: `_growend!`'s
            # store target is `%1 = load ptr, ptr %0` where
            # `%0 = getelementptr i8, ptr %".roots.#self#", 0`. MEASURED
            # (2026-08-06): the load carries NO extent metadata of any kind
            # (`dereferenceable`, `dereferenceable_or_null`, `align`, `range`,
            # … all absent), its pointer operand is a GEP off a function
            # ARGUMENT whose `dereferenceable` is 0, and NO allocation root for
            # the pointed-to object exists in this function — the adequate
            # `gc_alloc_obj(…, i64 24, …)` lives in the CALLER. So no local
            # predicate can establish the extent, and this arm does not pretend
            # to. Enforcement is deferred to BennettVM's out-of-reservation
            # bounds check, bead `bennettvm-pdqx`. NOTE, precisely: that check
            # rejects accesses landing outside ALL live reservations; it does
            # NOT reject a store that clobbers an ADJACENT live allocation
            # (measured — the arena/stack membership predicate admits both cells
            # of every one of the D1 repros). Closing THAT class needs pointer
            # provenance, which neither repo has. Tracked as a residual.
            #
            # Bennett-bvmd: the comparison is now in the TARGET'S OWN CELLS.
            # `_p06b_cell_ptr_target_kind` returns the capacity in the unit the
            # allocator actually reserves (byte cells for `julia.gc_alloc_obj`,
            # word cells for `malloc` / `alloca`), and the requirement is
            # converted into that same unit by the store's own stamp. For the
            # word tier `need == length(fw_p06b)` EXACTLY — byte-identical.
            ew_store_p06b = let rs = _root_scale(ptr, names, ptr_cells)
                rs === nothing ? 64 : 8 * rs[1]
            end
            scale_p06b = ew_store_p06b ÷ 8
            need_p06b = (offs_p06b[end] + 8) ÷ scale_p06b
            (tcells >= 0 && tcells < need_p06b) && _ir_error(inst,
                "aggregate store target reserves only $(tcells) " *
                "$(scale_p06b)-byte cell(s) but the decomposition of " *
                "$(string(vt)) writes $(need_p06b) — the surplus cells " *
                "belong to the NEXT " *
                "allocation and would be silently CLOBBERED (executed witness: " *
                "an `alloca i64` / `malloc(8)` receiving a 2-field store " *
                "overwrote its neighbour, EXPECTED 999 ACTUAL 42, no error). A " *
                "capacity of 0 means the reservation is not a compile-time " *
                "constant (a runtime `alloca` count or a non-constant allocator " *
                "size) or is not word-granular (e.g. `[K x i8]` reserves BYTE " *
                "cells), neither of which is a static capacity proof. " *
                "(Bennett-p06b, predicate `_p06b_alloca_cells` / " *
                "`_p06b_call_bytes`)")
            # (P5) Cell-granularity agreement across the target's other
            # address-forming uses — the CW-D4 / 9n3y split guard.
            # Bennett-bvmd: TIER-PARAMETRISED. `ew_store_p06b` is the stamp the
            # emission below will actually use, so the scan compares against the
            # emitter rather than against a hard-coded word granularity. For
            # `ew_store_p06b == 64` the predicate is today's rule verbatim.
            gviol = _p06b_granularity_violation(ptr, vt, ew_store_p06b, names,
                                                ptr_cells)
            gviol === nothing || _ir_error(inst,
                "aggregate store target is addressed at BOTH the " *
                "$(ew_store_p06b == 64 ? "WORD" : "BYTE") " *
                "granularity of this store's struct fields (cell stride " *
                "$(scale_p06b) bytes) and an incompatible granularity, via $(gviol). " *
                "BennettVM recovers a cell as `offset_bytes ÷ (elem_width ÷ " *
                "8)`, so the same byte offset would map to two different VM " *
                "cells (the CW-D4 / bennettvm-9n3y split). Refusing to WRITE " *
                "a whole aggregate through one of two disagreeing cell maps. " *
                "(Bennett-p06b, predicate `_p06b_granularity_violation` / " *
                "`_p06b_alias_group`)")
            # (P6) The value must be an `insertvalue` INSTRUCTION. This is
            # forced by BennettVM's own contract, not by taste: ingest fails
            # loud unless an `IRExtractValue.agg` names a value in `agg_dests`,
            # which is populated from `IRInsertValue.dest` (BennettVM
            # `src/ir/ingest.jl`, bead `bennettvm-acq`). A `zeroinitializer`
            # resolves to the ZeroAggSentinel (explicitly rejected there); a
            # `load {ptr,ptr}` is SILENTLY SKIPPED by the load arm while its
            # dest name stays registered, so it would name a never-built slot
            # family; `undef`/`poison` have no value a reversible VM could
            # invent and later restore. Rule 1: fail at the earliest point that
            # knows why, in the repo that owns the reason.
            (val isa LLVM.Instruction &&
             LLVM.opcode(val) == LLVM.API.LLVMInsertValue) || _ir_error(inst,
                "aggregate store value $(val) is not an `insertvalue` " *
                "instruction. The decomposition reads each field with " *
                "`IRExtractValue`, whose aggregate MUST name a value in " *
                "BennettVM's `agg_dests` registry — populated ONLY from " *
                "`IRInsertValue.dest` (bead `bennettvm-acq`). A " *
                "`zeroinitializer` / `undef` / `load`-produced aggregate has " *
                "no per-slot family, and a reversible VM cannot invent a " *
                "field value it could not later restore. (Bennett-p06b, " *
                "predicate: the `LLVMInsertValue` opcode test above)")
            # (P6') D4 — ... and so must its whole CHAIN, down to the root.
            # Checking only the outermost link admitted
            # `insertvalue (load {ptr,ptr}), …`: `IRInsertValue` has no
            # `agg_dests` membership guard on the ingest side (only
            # `IRExtractValue` does), so that chain died as a CONTEXTLESS
            # KeyError in the WRONG repo.
            let croot = _p06b_agg_chain_root_violation(val)
                croot === nothing || _ir_error(inst,
                    "aggregate store value $(val) heads an `insertvalue` chain " *
                    "whose ROOT is not certified: it bottoms out in $(croot). " *
                    "Only a `zeroinitializer` / `undef` / `poison` root is " *
                    "admitted — a root BennettVM's `agg_dests` never registers " *
                    "gives the chain no per-slot family, and `IRInsertValue` " *
                    "(unlike `IRExtractValue`) has NO membership guard at " *
                    "ingest, so the failure would surface as a contextless " *
                    "KeyError in the BennettVM repo instead of here. " *
                    "(Bennett-p06b, predicate " *
                    "`_p06b_agg_chain_root_violation`)")
            end
            # EMIT: field-ascending extract → offset → store triples. Every
            # constructor call is byte-identical IN FORM to the arm that
            # already emits it (`instructions.jl` extractvalue arm / D4 GEP arm
            # / D3 store arm), which is what makes cell agreement a syntactic
            # identity rather than a claim about two code paths.
            base_p06b = ssa(names[ptr.ref])
            agg_p06b = _operand(val, names)
            out_p06b = IRInst[]
            for k in 0:(length(fw_p06b) - 1)
                fname = _auto_name(counter)
                push!(out_p06b, IRExtractValue(fname, agg_p06b, k,
                                               0, length(fw_p06b), fw_p06b))
                aname = _auto_name(counter)
                # Bennett-bvmd: the stamp is the TARGET ROOT'S OWN scale, from
                # the same `_root_scale` the D4 GEP arm and (P5) consult. For a
                # `malloc`/`alloca`/scale-unknown target this is 64 —
                # byte-identical to the pre-bvmd literal. For a
                # `julia.gc_alloc_obj` target it is 8, so field k lands on byte
                # cell `o_k` and meets the byte GEPs that read it. ONE 64-bit
                # store per field either way: BennettVM's `MemoryStore` carries
                # no width and writes a WHOLE cell (`memory_floor.jl:156-168`),
                # so eight single-byte stores are neither expressible nor right.
                push!(out_p06b, IRPtrOffset(aname, base_p06b, offs_p06b[k + 1],
                                            ew_store_p06b))
                push!(out_p06b, IRStore(ssa(aname), ssa(fname), 64))
            end
            return out_p06b
        end
        # Bennett-lgzx / U114: was `vt isa LLVM.IntegerType || return nothing`
        # — silent drop violated CLAUDE.md §1. Error loud with the
        # actual stored-value type so the user can debug.
        vt isa LLVM.IntegerType || _ir_error(inst,
            "store of non-integer type $(vt) not supported " *
            "(Bennett-lgzx / U114). SoftFloat dispatch should reroute " *
            "Float64 stores to integer wrappers before extraction.")
        # Bennett-lgzx / U114: was `haskey(names, ptr.ref) || return nothing`
        # — silent drop. Error loud naming the pointer so the user can
        # trace the missing SSA registration.
        haskey(names, ptr.ref) || _ir_error(inst,
            "store target pointer is not a registered SSA name " *
            "(value=$(ptr)) — likely an unsupported pointer source " *
            "such as a global, ConstantExpr, or alias (Bennett-lgzx / U114).")
        return IRStore(ssa(names[ptr.ref]),
                       _operand(val, names),
                       LLVM.width(vt))
    end

    # alloca: `%dest = alloca ty[, i32 N]` -> IRAlloca. Only integer element
    # types are lowered; float / aggregate / pointer element types are skipped
    # (matches IRLoad policy — SoftFloat dispatch maps Float64 to UInt64
    # before IR extraction, so float allocas are rare in practice).
    # n_elems is :const if the operand is a ConstantInt, else :ssa (dynamic —
    # lowering currently rejects :ssa).
    if opc == LLVM.API.LLVMAlloca
        # Bennett-p06b: the whole reservation decision lives in ONE place,
        # `_alloca_reservation`, which p06b's target certification also calls.
        # PROVABLY BEHAVIOUR-PRESERVING vs the pre-p06b arm: the helper is that
        # arm's own branch logic verbatim (Bennett-munq / Bennett-ixiz ArrayType
        # mapping with the count operand discarded; the ADR 0020 D5c gated
        # `alloca ptr` -> 64; the integer case), and every type it returns
        # `nothing` for already fell through to a `return nothing`.
        # SHARING rather than mirroring is load-bearing: the mirror this
        # replaced drifted on the ArrayType count operand and produced a silent
        # clobber (hostile review N1). The arm's own under-reservation for
        # `alloca [K x iM], i32 N` is Bennett-uiqq, deliberately NOT fixed here.
        r_alloca = _alloca_reservation(inst, names, ptr_cells)
        r_alloca === nothing && return nothing
        return IRAlloca(dest, r_alloca[1], r_alloca[2])
    end

    # Bennett-3ptu — CW-D2 lever: DROP `fence` under the closed-world / BennettVM
    # cell model (`ptr_cells=true`). A `fence` is a pure memory-ordering barrier
    # with NO data effect — it constrains the visibility ordering of OTHER memory
    # ops across threads, but produces no value and mutates no state. In the
    # single-threaded, deterministic, history-reversible BennettVM there is no
    # concurrent observer for the barrier to order against, so the fence is a
    # genuine no-op: dropping it changes nothing and is trivially reversible.
    # `return nothing` is the established "emit no IR for this instruction" signal
    # here (same as the gc_preserve drop above and the silent-skip allocas/loads).
    # Every Julia callee in the fdict closed-world path emits 2 such fences (GC
    # safepoint / write-barrier fences), so this unblocks setindex!/rehash!/
    # ht_keyindex2_shorthash! extraction. Gate-off (`ptr_cells=false`) the fence
    # falls through to the existing "unsupported LLVM opcode" fail-loud below —
    # the circuit path is byte-identical and does NOT silently drop the fence
    # (CLAUDE.md §1). Exact-opcode-scoped: only `fence` is admitted (mirrors the
    # exact-name scoping of the gc_preserve drop in Bennett-zf5v).
    if opc == LLVM.API.LLVMFence
        if ptr_cells
            return nothing
        end
        # ptr_cells=false → fall through to the fail-loud below (no change to
        # circuit-path behaviour).
    end

    _ir_error(inst, "unsupported LLVM opcode")
end

