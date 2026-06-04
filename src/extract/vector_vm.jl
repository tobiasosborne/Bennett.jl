# ---- SC9 Case A — the `mem=:vm` Julia-`Vector` → IRAlloca(dyn)+IRVarGEP recogniser ----
#
# This file is the FRONT-END half of BennettVM's reversible dynamic-`Vector`
# case (PRD v4 §3.6.2 Case A; ADR 0009 / 0016). When a Julia function allocates
# a `Vector{T}(undef, n)`, writes a data-dependent pattern into it in a loop,
# reads it back, and reduces, the standard `mem=:auto`/`:heap` walks reject it
# at the GC / GenericMemory wall. This recogniser is the `mem=:vm` Case-A arm:
# it STRIPS Julia's GC + GenericMemory skeleton (the GC frame, the
# `jl_alloc_genericmemory_unchecked` Memory backing, the `julia.gc_alloc_obj`
# Array wrapper, the `julia.gc_loaded` data-pointer launder, the MemoryRef
# chain, and the GenericMemory-size / `Int8(i)`-inexact / bounds-check throw
# diamonds) and rewrites the element traffic into the language-neutral
# `IRAlloca(dyn) + IRVarGEP + IRStore/IRLoad` shape BennettVM ingests — the
# SAME shape the C `frtN.ll` produces (BennettVM `test/test_dyn_roundtrip.jl`,
# already proven). Crucially, unlike `:heap`/Dict (which collapse to one block),
# Case A PRESERVES the multi-block WRITE/READ loop CFG (ADR 0016 D7): the loop
# φ-nodes, induction `add`/`sub`/`icmp`, and back-edge flow through unchanged,
# so the recogniser emits a MULTI-block `ParsedIR` natively.
#
# # The design map (ADR 0016, against the REAL O0 IR of `fvec`/`vsum`)
#
# A `Vector{T}(undef, n)` + `v[i]=…` + `s+=v[i]` lowers (Julia 1.12.5,
# optimize=FALSE — D1 pins O0; O2 is a different, SIMD-vectorised program) to:
#   * a GC frame + the `julia.get_pgcstack` TLS read — DROPPED skeleton.
#   * `%sz = extractvalue @llvm.smul.with.overflow(%n, STRIDE)` then
#     `%M = jl_alloc_genericmemory_unchecked(ptls, %sz, …)` — the Memory
#     backing. BECOMES the `DynAlloca(base, n_operand=%n)`; the byte size is
#     DROPPED (the VM is cell-addressed). STRIDE (1 for i8, 8 for i64) is
#     recovered here and cross-checked (D4/D6).
#   * `store i64 %n, GEP({i64,ptr},%M,0,0)` — the Memory LENGTH field store.
#     This is the element COUNT `n_elems` (D4, triple-witnessed vs the smul
#     operand and the source arg). DROPPED (its value `%n` becomes n_operand).
#   * `julia.gc_alloc_obj` + the `{data,Memory,size}` wrapper stores — the
#     Array wrapper. DROPPED.
#   * per element: `%off = sub %i, 1`; `%bo = mul %off, STRIDE`;
#     `%d = call julia.gc_loaded(%mem, %data)`; `%addr = GEP i8 %d, %bo`;
#     `store iW %v, %addr` / `%r = load iW, %addr`. The `mul`/`gc_loaded`/GEP
#     chain is re-rooted to a single `IRVarGEP(gep, base, index=%off, W)` onto
#     the `DynAlloca` base (cell stride 1; `%off` SURVIVES as a normal IRBinOp);
#     the store/load become `IRStore`/`IRLoad` (D5/D6).
#   * the size-check / inexact / bounds throw diamonds — `unreachable`-
#     terminated throw blocks + their guarding `br`s — COLLAPSED (the throw arm
#     is dead; the guarding `br` on a skeleton condition is dropped).
#
# # Soundness discipline (CLAUDE.md §1, generalised from heap.jl M2)
#
# The catastrophe is a SILENT MISCOMPILE — a dropped LIVE value, a mis-recovered
# stride (the b5x ÷8 trap), or a wrong `n_elems` (over-allocating STRIDE× and
# retracting the wrong region on reverse). So this is a PARTITION recogniser
# (ADR 0016 D2): every instruction is positively classified into
# {dropped skeleton, re-rooted element traffic, passed-through user
# computation, terminator}; anything unclassifiable REJECTS LOUD (closed-world).
# heap.jl's machinery is REUSED (Law 2): `_heap_callee_name`,
# `_heap_operand_ref(s)`, `_heap_num_operands`, `_heap_is_allowlisted_tls_asm`,
# `_heap_is_gep`, `_heap_gep_info`, `_heap_ref_is_instruction`,
# `_heap_ref_is_const_int`, `_assert_memory_layout`, `_heap_value_for_ref`,
# `_operand`/`_iwidth`. Per ADR 0016 we DO NOT call `_heap_assert_no_backedge`
# — Case A PRESERVES the loop back-edge.
#
# # Ref
#   * docs/adr/0016-case-a-mem-vm-recognizer.md — D1–D8 + the fail-loud matrix.
#   * docs/adr/0009-dynamic-size-memory.md — the DynAlloca (base,n) L2 delta +
#     the single-dynamic-array fixed-base floor BennettVM ingests into.
#   * src/extract/heap.jl — the reused low-level LLVM helpers (Law 2).
#   * src/extract/dict_vm.jl — the sibling `mem=:vm` partition + fail-loud arm.
#   * BennettVM src/ir/{ingest,array_index,alloca}.jl — what ingest ACCEPTS
#     (already proven on `frtN.ll`); the emitted IR must match.
#   * CLAUDE.md §1 (fail loud), §2 (reuse heap.jl), §9, §11.

# Allowlisted O0 callees (ADR 0016 Q2). The GC allocator differs O0
# (`julia.gc_alloc_obj`) vs O2 (`ijl_gc_small_alloc`); the Memory allocator is
# `jl_alloc_genericmemory_unchecked`; `julia.gc_loaded` is the pure data-ptr
# launder (D5); `julia.get_pgcstack` is the TLS-base read; `jl_argument_error`
# is the GenericMemory-size-overflow throw. Matched EXACT against callee FUNCTION
# names (the `_NNN` session suffix on `j_throw_*` is matched as `\d+`).
const _VEC_VM_MEM_ALLOC      = "jl_alloc_genericmemory_unchecked"
const _VEC_VM_GC_LOADED      = "julia.gc_loaded"
const _VEC_VM_GC_ALLOC_OBJ   = "julia.gc_alloc_obj"
const _VEC_VM_GC_ALLOC_OBJ2  = "ijl_gc_small_alloc"   # O2 form (kept; moot at O0)
const _VEC_VM_PGCSTACK       = "julia.get_pgcstack"
const _VEC_VM_ARGERR         = "jl_argument_error"
const _VEC_VM_INEXACT_RE     = r"^j_throw_inexacterror_\d+$"

function _vec_vm_error(reason::AbstractString)
    error("ir_extract.jl: mem=:vm Vector (Case A) recogniser: $reason " *
          "(Bennett-jfw6; ADR 0016)")
end

"""
    _vec_vm_is_recognised(func) -> Bool

True iff `func` allocates a Julia `Vector`/`GenericMemory` via
`jl_alloc_genericmemory_unchecked` — the gate that routes a `mem=:vm` function
into the Case-A Vector recogniser (vs the Case-B Dict arm, which keys off the
`setindex!`/`getindex`/`delete!` callees). A `:vm` function with neither is
neither case and reaches the module_walk reject.
"""
function _vec_vm_is_recognised(func::LLVM.Function)::Bool
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_callee_name(inst) == _VEC_VM_MEM_ALLOC && return true
    end
    return false
end

# Result of structural recognition of the single dynamic Vector backing.
#   mem_alloc  — the `jl_alloc_genericmemory_unchecked` Memory result ref.
#   n_arg      — the SSA value ref of the element COUNT (the length-store value,
#                == the smul source operand, == the source arg) — D4.
#   stride     — the recovered element byte stride (1 for i8, 8 for i64) — D6.
#   wrapper    — the `julia.gc_alloc_obj` Array wrapper result ref (or nothing).
struct _VecBacking
    mem_alloc::_LLVMRef
    n_arg::_LLVMRef
    stride::Int
    wrapper::Union{Nothing,_LLVMRef}
end

# True iff `inst` is a call whose callee name matches `name`.
_vec_vm_is_call(inst::LLVM.Instruction, name::AbstractString) =
    _heap_callee_name(inst) == name

# Find the (unique) instruction satisfying `pred`, or `nothing`.
function _vec_vm_find(func::LLVM.Function, pred; what::AbstractString="instruction")
    found::Union{Nothing,LLVM.Instruction} = nothing
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        pred(inst) || continue
        found === nothing ||
            _vec_vm_error("ambiguous IR shape — two `$what` instructions match " *
                          "a uniqueness predicate (expected exactly one); " *
                          "second = $(_heap_vname(inst))")
        found = inst
    end
    return found
end

# The 1st (1-based) operand ref of `inst`, or error.
_vec_vm_op(inst::LLVM.Instruction, i::Int) = _heap_operand_ref(inst, i)

# Walk back through `extractvalue`/`call llvm.smul.with.overflow` to recover the
# byte size operand chain: the Memory alloc's size operand is
# `%sz = extractvalue { i64,i1 } %smul, 0`, and `%smul = call
# @llvm.smul.with.overflow.i64(%n, STRIDE)`. Returns `(n_ref, stride)`.
function _vec_vm_size_chain(func::LLVM.Function, size_ref::_LLVMRef)
    inst_by_ref = Dict{_LLVMRef,LLVM.Instruction}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst_by_ref[inst.ref] = inst
    end
    ev = get(inst_by_ref, size_ref, nothing)
    (ev !== nothing && LLVM.opcode(ev) == LLVM.API.LLVMExtractValue) ||
        _vec_vm_error("Memory alloc size operand is not an `extractvalue` of " *
                      "an `llvm.smul.with.overflow` — unrecognised size shape")
    smul = get(inst_by_ref, _vec_vm_op(ev, 1), nothing)
    (smul !== nothing &&
     startswith(_heap_callee_name(smul), "llvm.smul.with.overflow.")) ||
        _vec_vm_error("Memory size `extractvalue` source is not an " *
                      "`llvm.smul.with.overflow` call — unrecognised size shape")
    # smul operands: [%n, STRIDE, callee]; STRIDE is a constant int.
    n_ref = _vec_vm_op(smul, 1)
    stride_ref = _vec_vm_op(smul, 2)
    _heap_ref_is_const_int(stride_ref) ||
        _vec_vm_error("element byte stride (smul multiplicand) is not a " *
                      "constant — runtime-stride layout out of Case-A scope")
    stride = _heap_const_int_sval(stride_ref)
    stride >= 1 ||
        _vec_vm_error("recovered element byte stride $stride is not positive")
    return (n_ref, stride)
end

"""
    _vec_vm_recognise(func) -> _VecBacking

Structurally recognise the single dynamic `Vector` backing and recover the
element COUNT operand + the byte stride (ADR 0016 D4/D6). FAILS LOUD on ≥2
backings (→ the multi-array `uil` bead), on a missing/ambiguous length store,
or on a stride disagreement between the smul multiplicand and the
Memory-length / GEP path.
"""
function _vec_vm_recognise(func::LLVM.Function)::_VecBacking
    allocs = LLVM.Instruction[]
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _vec_vm_is_call(inst, _VEC_VM_MEM_ALLOC) && push!(allocs, inst)
    end
    isempty(allocs) &&
        _vec_vm_error("no `@$_VEC_VM_MEM_ALLOC` Memory allocation found")
    length(allocs) == 1 ||
        _vec_vm_error("$(length(allocs)) `@$_VEC_VM_MEM_ALLOC` calls — Case A " *
                      "(ADR 0016 D8) models a SINGLE dynamic Vector backing per " *
                      "routine; multiple dynamic arrays need the runtime " *
                      "bump-pointer (bead `bennettvm-uil`). Rule 1 fail-loud")
    mem_alloc = allocs[1]
    # The alloc's SIZE operand: operands are [ptls, %sz, GenericMemory_type,
    # callee]; the byte size is operand 2 (1-based).
    _heap_num_operands(mem_alloc) >= 2 ||
        _vec_vm_error("Memory alloc has too few operands")
    n_ref, stride = _vec_vm_size_chain(func, _vec_vm_op(mem_alloc, 2))

    # The Memory LENGTH field store: `store i64 %n, GEP({i64,ptr},%M,0,0)` —
    # the element COUNT (D4). Its value must be the SAME `%n` as the smul source
    # (triple witness: smul source, length store, source arg all agree).
    len_store = _vec_vm_find(func, function (inst)
        LLVM.opcode(inst) == LLVM.API.LLVMStore || return false
        _heap_num_operands(inst) >= 2 || return false
        addr = _heap_operand_ref(inst, 2)
        _heap_ref_is_instruction(addr) || return false
        # addr is a struct GEP off the Memory object at field 0 (the length).
        addr === _vec_vm_len_gep(func, mem_alloc.ref)
    end; what="Memory length store")
    len_store === nothing &&
        _vec_vm_error("no Memory length-field store `store i64 %n, " *
                      "GEP(Memory,0,0)` found — cannot witness the element count")
    len_val = _heap_operand_ref(len_store, 1)
    len_val === n_ref ||
        _vec_vm_error("Memory length-store value disagrees with the smul size " *
                      "source — the element-count triple-witness (D4) failed; " *
                      "refusing to guess `n_elems`")

    return _VecBacking(mem_alloc.ref, n_ref, stride, nothing)
end

# The unique `GEP({i64,ptr}, %M, 0, 0)` length-field pointer off the Memory
# object `mem`, or `nothing`. (A struct GEP with two zero indices → field 0.)
function _vec_vm_len_gep(func::LLVM.Function, mem::_LLVMRef)
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_is_gep(inst) || continue
        _heap_operand_ref(inst, 1) === mem || continue
        gi = _heap_gep_info(inst)
        # field-0 struct GEP: non-simple (3 operands incl. base) with all-zero
        # indices. `_heap_gep_info` marks 3-operand GEPs non-simple; check the
        # two index operands are constant 0.
        n = _heap_num_operands(inst)
        n == 3 || continue
        i1 = _heap_operand_ref(inst, 2); i2 = _heap_operand_ref(inst, 3)
        (_heap_ref_is_const_int(i1) && _heap_const_int_sval(i1) == 0 &&
         _heap_ref_is_const_int(i2) && _heap_const_int_sval(i2) == 0) || continue
        return inst.ref
    end
    return nothing
end
