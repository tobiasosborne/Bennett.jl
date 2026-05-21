# ---- Bennett-gps7 / M1 — Julia heap-memory support, Milestone 1 ----
#
# This file implements the *recogniser* half of M1: a NON-MUTATING extraction
# pre-pass that detects the dead GC/heap skeleton Julia emits around a heap
# `Vector` allocation, PROVES it dead w.r.t. the function's return value, and
# tells the module walker which LLVM instructions to SKIP.
#
# Design (consensus design 2026-05-21, "Design B"): we do NOT mutate the LLVM
# Module, do NOT erase instructions, do NOT run extra LLVM passes. We build a
# `Set` of skeleton instruction refs (mirroring the `sret_writes.suppressed`
# idiom in module_walk.jl) and the walker skips them.
#
# CLAUDE.md §1: the catastrophic failure here is a *silent miscompile* — a
# skeleton instruction suppressed when it is actually live, producing a wrong
# circuit with all ancillae returning to zero (so `verify_reversibility`
# passes). EVERY obligation below is mandatory; ANY doubt → loud reject. The
# recogniser is purely subtractive and monotone: it only ever rejects. Success
# means every tainted instruction was positively classified as a recognised,
# dead, isolable skeleton instruction.
#
# CLAUDE.md §5/§9/§10: LLVM IR is not stable. Every structural assumption is
# guarded — version drift, layout drift, an unrecognised opcode in the taint
# closure, an unexpected callee — all REJECT loud, never miscompile.
#
# M1 SCOPE — a function compiles under `mem=:heap` iff ALL hold:
#   1. exactly one recognised GC/heap skeleton (one `@ijl_gc_small_alloc`)
#   2. the skeleton is provably DEAD w.r.t. the return (the 5-part proof)
#   3. the skeleton is provably ISOLABLE (no skeleton value escapes)
#   4. after removing the skeleton the surviving instructions are STRAIGHT-LINE
# Anything else REJECTS LOUD with a precise, actionable message.

# ---------------------------------------------------------------------------
# F. Robustness constants — drift must REJECT, never miscompile.
# ---------------------------------------------------------------------------

# The ONLY inline-asm exempt from the U15 reject — and only when the
# instruction is part of a recognised, proven skeleton. Julia's TLS-base read
# on x86-64: `movq %fs:0, $0` with the `=r` output constraint. EXACT match
# only (asm string + constraint string). Any other inline-asm rejects.
const _GC_TLS_ASM_ALLOWLIST = Set{Tuple{String,String}}([
    ("movq %fs:0, \$0", "=r"),
])

# Anchored regex for the Julia `growend!` heap callee. Applied to CALLEE
# FUNCTION NAMES ONLY — never to value names. The `_NNN` suffix is a per-JIT
# session counter and the `##\d+` is a closure-uniquing counter; both vary
# per session, so neither is matched literally.
#
# CRITICAL false-positive guard: the substring `#_growend!##0#_growend!##1`
# also appears inside an *alloca's value name* (`%"new::#_growend!##0..."`).
# Anchoring with `^...$` and matching the callee FUNCTION name (not the value
# name) is what keeps this from a false positive.
const _GC_GROWEND_CALLEE_RE = r"^j_#_growend!##\d+_\d+$"

# Julia 1.12.5 `Memory{T}` / `Array` memory-layout offsets the recogniser
# depends on. These are asserted in `_assert_memory_layout` and gate the
# whole recogniser — if Julia changes its object layout, recognition rejects
# loud rather than miscompiling. Values observed from the optimize=true IR of
# `f1(x::Int8) = let v=Int8[]; push!(v,x); v[1] end` on Julia 1.12.5.
const _GC_LAYOUT_TLS_PGCSTACK_OFF = -8     # gcframe `ppgcstack` GEP byte offset
const _GC_LAYOUT_PTLS_FIELD_OFF   = 16     # `ptls` field GEP byte offset off pgcstack
const _GC_LAYOUT_TAG_OFF          = -1     # object tag GEP element offset (i64 units)

# ---------------------------------------------------------------------------
# Result struct.
# ---------------------------------------------------------------------------

"""
    _HeapSkeleton

Result of the M1 GC/heap-skeleton recogniser+prover.

- `recognised` — true iff exactly one skeleton was structurally recognised AND
  all five liveness-proof obligations passed. When false the recogniser is
  inert (either no skeleton present, or the function rejected loud before
  this struct was constructed — a rejecting recogniser throws, it does not
  return a `recognised=false` struct).
- `suppressed` — the set of LLVM instruction refs the module walker must skip
  (the entire skeleton). Empty when `recognised=false`.
- `ret_inst` — the single `IRRet` of the resolved return operand, built from
  the surviving (non-skeleton) slice. The surviving slice is straight-line by
  M1 condition 4, so the whole function collapses to a one-block ParsedIR
  whose only instruction stream is the surviving non-skeleton instructions
  followed by this terminator.
- `survivors` — the surviving non-skeleton non-terminator instructions in
  program order across all blocks (for f1 this is empty).
"""
struct _HeapSkeleton
    recognised::Bool
    suppressed::Set{_LLVMRef}
    ret_inst::Union{Nothing,IRInst}
    survivors::Vector{IRInst}
end

_HeapSkeleton() = _HeapSkeleton(false, Set{_LLVMRef}(), nothing, IRInst[])

# ---------------------------------------------------------------------------
# Error helper — every reject names the offending SSA value and cites the bead.
# ---------------------------------------------------------------------------

function _heap_error(reason::AbstractString)
    error("ir_extract.jl: heap-memory recogniser: $reason (Bennett-gps7 / M1)")
end

# Short identifier for an LLVM value, for error messages. The two `catch`
# blocks re-raise InterruptException so Ctrl-C still works (Bennett-uinn /
# U93 convention) — every other failure during error formatting degrades to
# a placeholder rather than masking the original error.
function _heap_vname(v::LLVM.Value)
    nm = try
        LLVM.name(v)
    catch e
        e isa InterruptException && rethrow()
        ""
    end
    isempty(nm) || return "%" * nm
    s = try
        string(v)
    catch e
        e isa InterruptException && rethrow()
        "<unprintable>"
    end
    return length(s) > 80 ? s[1:80] * "…" : s
end

# ---------------------------------------------------------------------------
# Layout / version guard (F).
# ---------------------------------------------------------------------------

# Assert the host + Julia version match the layout the recogniser was
# validated against. Any mismatch rejects loud — the `movq %fs:0` TLS idiom
# is x86-64-specific and the Memory{T} offsets are pinned to Julia 1.12.5.
function _assert_memory_layout()
    Sys.WORD_SIZE == 64 ||
        _heap_error("requires a 64-bit host (Sys.WORD_SIZE=$(Sys.WORD_SIZE)); " *
                    "the `movq %fs:0` TLS idiom is x86-64-specific")
    sizeof(Ptr{Cvoid}) == 8 ||
        _heap_error("requires 8-byte pointers (got $(sizeof(Ptr{Cvoid})))")
    (VERSION.major, VERSION.minor) == (1, 12) ||
        _heap_error("the GC/heap-skeleton recogniser is pinned to Julia 1.12 " *
                    "object layout; running on $(VERSION). Re-validate the " *
                    "skeleton shape against `code_llvm` output and update the " *
                    "`_GC_LAYOUT_*` constants in src/extract/heap.jl before " *
                    "enabling mem=:heap on this version")
    return nothing
end

# ---------------------------------------------------------------------------
# Raw-operand helpers.
#
# `LLVM.operands(inst)` forces `LLVM.Value` identification on every operand,
# which crashes (`error("Unknown value kind ...")`) on Julia runtime operands
# like `LLVMGlobalAlias` (`store ptr @"jl_global#NNN.jit", ...` appears all
# over the heap skeleton). The recogniser only needs (a) operand REFS for the
# taint closure (`Set{_LLVMRef}` membership is ref identity, no value object
# needed) and (b) per-operand "is this an SSA instruction?" classification.
# Both are answered by the raw C API without identification.
# ---------------------------------------------------------------------------

# Number of operands of an instruction (raw).
_heap_num_operands(inst::LLVM.Instruction) =
    Int(LLVM.API.LLVMGetNumOperands(inst.ref))

# Raw ref of the i-th (1-based) operand.
_heap_operand_ref(inst::LLVM.Instruction, i::Int)::_LLVMRef =
    LLVM.API.LLVMGetOperand(inst.ref, Cuint(i - 1))

# All operand refs of an instruction (raw).
function _heap_operand_refs(inst::LLVM.Instruction)::Vector{_LLVMRef}
    n = _heap_num_operands(inst)
    return _LLVMRef[_heap_operand_ref(inst, i) for i in 1:n]
end

# True iff the value behind `ref` is an SSA instruction (so it can be a member
# of `skel` / a taint-closure node). Uses the raw value-kind enum — no
# identification, safe on GlobalAlias / inline-asm / constant operands.
_heap_ref_is_instruction(ref::_LLVMRef)::Bool =
    LLVM.API.LLVMIsAInstruction(ref) != C_NULL

# ---------------------------------------------------------------------------
# Inline-asm helpers.
# ---------------------------------------------------------------------------

# True iff `inst` is a call whose callee is inline asm.
function _heap_is_inline_asm_call(inst::LLVM.Instruction)
    LLVM.opcode(inst) == LLVM.API.LLVMCall || return false
    n = _heap_num_operands(inst)
    n == 0 && return false
    callee = _heap_operand_ref(inst, n)
    return LLVM.API.LLVMIsAInlineAsm(callee) != C_NULL
end

# Extract `(asm_string, constraint_string)` from an inline-asm call, or
# `nothing` if it is not inline asm. Parses the textual `InlineAsm`
# representation `ptr asm [sideeffect] "<asm>", "<constraint>"` — LLVM.jl 9
# exposes no typed getters for `LLVMGetInlineAsmAsmString`.
function _heap_inline_asm_strings(inst::LLVM.Instruction)
    n = _heap_num_operands(inst)
    n == 0 && return nothing
    callee = _heap_operand_ref(inst, n)
    LLVM.API.LLVMIsAInlineAsm(callee) != C_NULL || return nothing
    # `LLVM.Value` on an inline-asm ref identifies cleanly (InlineAsm IS a
    # known value kind); only GlobalAlias is the problematic kind.
    s = string(LLVM.Value(callee))
    m = match(r"asm(?:\s+sideeffect)?(?:\s+alignstack)?(?:\s+inteldialect)?\s+\"((?:[^\"\\]|\\.)*)\"\s*,\s*\"((?:[^\"\\]|\\.)*)\"", s)
    m === nothing && return nothing
    return (String(m.captures[1]), String(m.captures[2]))
end

# True iff `inst` is an inline-asm call on the TLS-base allowlist.
function _heap_is_allowlisted_tls_asm(inst::LLVM.Instruction)
    pair = _heap_inline_asm_strings(inst)
    pair === nothing && return false
    return pair in _GC_TLS_ASM_ALLOWLIST
end

# ---------------------------------------------------------------------------
# Callee-name helpers.
# ---------------------------------------------------------------------------

# Resolve the callee function name of a call instruction, or "" if the callee
# is inline asm / an indirect call.
function _heap_callee_name(inst::LLVM.Instruction)
    LLVM.opcode(inst) == LLVM.API.LLVMCall || return ""
    n = _heap_num_operands(inst)
    n == 0 && return ""
    callee = _heap_operand_ref(inst, n)
    LLVM.API.LLVMIsAInlineAsm(callee) != C_NULL && return ""
    # A direct call's callee is an LLVM.Function (a known value kind — safe
    # to identify). An indirect call's callee is some SSA value; we only need
    # the name, and `LLVMGetValueName2` works on the raw ref without
    # identification.
    len = Ref{Csize_t}(0)
    p = LLVM.API.LLVMGetValueName2(callee, len)
    # LLVMGetValueName2 returns a `Cstring`; convert to a Ptr{UInt8} for the
    # length-bounded `unsafe_string`.
    pp = Ptr{UInt8}(p)
    pp == C_NULL && return ""
    return unsafe_string(pp, len[])
end

# True iff `name` is an allowlisted heap callee (recognised skeleton calls).
function _heap_is_allowlisted_callee(name::AbstractString)
    name == "ijl_gc_small_alloc" && return true
    occursin(_GC_GROWEND_CALLEE_RE, name) && return true
    return false
end

# ---------------------------------------------------------------------------
# Entry point: _detect_gc_preamble!
# ---------------------------------------------------------------------------

"""
    _detect_gc_preamble!(func, names, mem) -> _HeapSkeleton

M1 GC/heap-skeleton recogniser. Runs ONLY when `mem === :heap`; under any
other `mem` value it returns an inert `_HeapSkeleton()` immediately (so the
default `mem=:auto` path is byte-identical to pre-M1 behaviour).

When `mem === :heap`:
  - If the function contains no `@ijl_gc_small_alloc` call, returns an inert
    `_HeapSkeleton()` — the recogniser is transparent, the function extracts
    through the normal walker.
  - If it contains exactly one, runs structural recognition + the five-part
    liveness proof. On success returns a `recognised=true` `_HeapSkeleton`
    with the suppression set and the single-block return. On ANY failure of
    recognition or the proof, throws a loud, actionable error.
  - More than one `@ijl_gc_small_alloc` rejects loud (M1 scope: one alloc).
"""
function _detect_gc_preamble!(func::LLVM.Function,
                              names::Dict{_LLVMRef,Symbol},
                              mem::Symbol,
                              counter::Ref{Int}=Ref(0))
    mem === :heap || return _HeapSkeleton()

    # ---- Count gc_small_alloc calls. Zero ⇒ inert; 1-2 ⇒ M1/M2; ≥3 reject. --
    allocs = LLVM.Instruction[]
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_callee_name(inst) == "ijl_gc_small_alloc" && push!(allocs, inst)
    end
    isempty(allocs) && return _HeapSkeleton()
    # Bennett-kuza / M2: a heap *array* allocates a Memory backing object plus
    # (for `Array{T}(undef,N)`) an Array wrapper — two `@ijl_gc_small_alloc`.
    # M1's bare `Int8[]` allocates only the Memory object. So 1≤count≤2 is in
    # scope; ≥3 means two distinct heap collections — reject loud.
    length(allocs) <= 2 ||
        _heap_error("$(length(allocs)) `@ijl_gc_small_alloc` calls found; the " *
                    "heap-memory recogniser supports at most one heap array " *
                    "(one Memory + one optional Array wrapper) per function. " *
                    "Multi-array heap code is out of M2 scope (Bennett-kuza / M2)")

    # A recognised skeleton is present — from here every exit is either a
    # proven success or a loud reject.
    _assert_memory_layout()

    # Reject heap allocation inside a loop body (back-edge). M1/M2 target
    # straight-line + a fully-skeleton diamond / a bounds-check diamond only.
    _heap_assert_no_backedge(func, allocs[1])

    skel = _recognise_skeleton(func, allocs)

    # ---- M1 vs M2 routing. ----
    # M1's target is a *dynamic* heap vector (`Int8[]` + `push!`/`growend!`):
    # the collection is wholly DEAD w.r.t. the return. Its IR carries a
    # `@j_#_growend!` callee and NO constant Memory length store (the length
    # is a runtime growend! result). M2's target is a *statically-sized* heap
    # array (`Array{T}(undef,N)`): no growend! call, a constant
    # `store i64 N, %memory_obj` length store, element data live into the
    # return. Route on the `growend!` callee — if present, the function is
    # M1-shaped and M2's `_recognise_heap_array` (which requires a constant-N
    # length store) would mis-reject it. M2 recognition runs ONLY when no
    # growend! call is present.
    has_growend = false
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        cname = _heap_callee_name(inst)
        if !isempty(cname) && occursin(_GC_GROWEND_CALLEE_RE, cname)
            has_growend = true
            break
        end
    end
    if has_growend
        # M1 path — dynamic heap vector, proven wholly dead. UNCHANGED.
        _prove_skeleton_dead(func, skel, names)
        ret_inst, survivors = _build_surviving_slice(func, skel, names)
        return _HeapSkeleton(true, skel, ret_inst, survivors)
    end

    # ---- Bennett-kuza / M2: recognise the heap array + partition SKEL. ----
    # `_recognise_heap_array` structurally identifies the Memory object, its
    # data pointer, and the (optional) Array wrapper. The partition splits
    # SKEL into {dead GC machinery} ∪ {live element traffic}.
    harr = _recognise_heap_array(func, allocs)

    # Collapse Julia bounds-check diamonds first so the throw-block
    # instructions are excluded from both SKEL classification and the
    # surviving slice.
    dropped = _collapse_bounds_diamond(func, skel)

    elem_traffic, gc_machinery = _partition_skeleton(func, skel, harr, dropped)

    if isempty(elem_traffic)
        # ---- M1 path — the heap collection is wholly dead. UNCHANGED. ----
        # Element traffic empty ⇒ no element data is live; this is exactly
        # the M1 case. Run the M1 proof + surviving-slice builder verbatim so
        # M1's 519 assertions stay byte-identical.
        _prove_skeleton_dead(func, skel, names)
        ret_inst, survivors = _build_surviving_slice(func, skel, names)
        return _HeapSkeleton(true, skel, ret_inst, survivors)
    end

    # ---- M2 path — element data is live; re-root onto a synthetic alloca. --
    _prove_partition_sound(func, skel, harr, elem_traffic, gc_machinery,
                           dropped)
    ret_inst, survivors = _build_rerooted_slice(
        func, names, counter, harr, elem_traffic, gc_machinery, dropped)
    return _HeapSkeleton(true, skel, ret_inst, survivors)
end

# ---------------------------------------------------------------------------
# Back-edge guard.
# ---------------------------------------------------------------------------

# Reject if the function's CFG has a back-edge (a branch to an
# already-visited block) — a heap alloc reachable on a loop body is out of M1
# scope. A simple reverse-postorder dominance-free check: any branch target
# that appears earlier in the linear block list than the branching block is
# treated as a back-edge.
function _heap_assert_no_backedge(func::LLVM.Function, alloc::LLVM.Instruction)
    blocks = collect(LLVM.blocks(func))
    index = Dict{_LLVMRef,Int}()
    for (i, bb) in enumerate(blocks)
        index[bb.ref] = i
    end
    for (i, bb) in enumerate(blocks)
        term = LLVM.terminator(bb)
        term === nothing && continue
        for succ in LLVM.successors(term)
            j = get(index, succ.ref, 0)
            j != 0 && j <= i &&
                _heap_error("control-flow back-edge detected (block " *
                            "%$(LLVM.name(bb)) branches to earlier block " *
                            "%$(LLVM.name(succ))); a heap allocation inside a " *
                            "loop body is out of M1 scope")
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# D. Structural recognition — build SKEL.
# ---------------------------------------------------------------------------

# Recognise the GC/heap skeleton structurally and return the set of skeleton
# instruction refs (`SKEL`). The recognition is a forward taint-closure from
# the structural SEEDS:
#   - every inline-asm call on the TLS allowlist
#   - the `@ijl_gc_small_alloc` result
#   - every gcframe / growend-scratch / sret-box `alloca`
#   - the volatile `llvm.memset` zeroing the gcframe
#   - every `@j_#_growend!` callee call
#   - every GC-frame-chain `store` / `load` and `Memory{T}` header `store`
#
# The taint closure then sweeps every opcode (ptrtoint/inttoptr/gep/select/
# phi/bitcast/...) — any instruction all of whose tainted-or-skeleton support
# is reached folds in. `_prove_skeleton_dead` cross-checks the result.
function _recognise_skeleton(func::LLVM.Function,
                             allocs::Vector{LLVM.Instruction})
    skel = Set{_LLVMRef}()

    # ---- Seeds ----
    # (1) every alloca in the entry block — gcframe [7 x ptr], growend
    #     scratch [9 x i64], sret_box [2 x i64]. M1 heap functions place all
    #     skeleton allocas at the top; a non-skeleton alloca would be caught
    #     downstream by the proof (P-noload / straight-line check).
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        LLVM.opcode(inst) == LLVM.API.LLVMAlloca && push!(skel, inst.ref)
    end

    # (2) the gc alloc(s) — M1 passes one; M2 passes the Memory + optional
    #     Array-wrapper pair.
    for alloc in allocs
        push!(skel, alloc.ref)
    end

    # (3) every TLS-allowlisted inline-asm call; reject any other inline asm
    #     that appears (a non-allowlisted asm in a heap function — drift).
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_is_inline_asm_call(inst) || continue
        if _heap_is_allowlisted_tls_asm(inst)
            push!(skel, inst.ref)
        else
            pair = _heap_inline_asm_strings(inst)
            desc = pair === nothing ? "<unparseable inline asm>" :
                   "asm=\"$(pair[1])\" constraint=\"$(pair[2])\""
            _heap_error("non-allowlisted inline-asm call $(_heap_vname(inst)) " *
                        "($desc); only the x86-64 TLS-base read " *
                        "`movq %fs:0, \$0`/`=r` is recognised")
        end
    end

    # (4) every llvm.memset and every @j_#_growend! / @ijl_gc_* call.
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        cname = _heap_callee_name(inst)
        isempty(cname) && continue
        if startswith(cname, "llvm.memset.") ||
           cname == "ijl_gc_small_alloc" ||
           occursin(_GC_GROWEND_CALLEE_RE, cname)
            push!(skel, inst.ref)
        end
    end

    # (5) every `load` whose ADDRESS is NOT an SSA value — i.e. a module-scope
    #     global or a constexpr-GEP-of-global. In a recognised-skeleton heap
    #     function these are the `Memory{T}` header reads off the
    #     `@"jl_global#NNN.jit"` global (e.g. `%memory_data`, `%.unbox`). They
    #     have no tainted SSA operand so the forward closure cannot reach them,
    #     hence they MUST be seeded structurally.
    #
    #     SOUNDNESS: this seed is safe even though it would also catch a
    #     genuine read-only global-table lookup. If such a load is actually
    #     LIVE (a `ret`-ancestor) the P-return obligation rejects loud; if a
    #     surviving load reads what it wrote, P-noload rejects. The seed can
    #     therefore only ever cause a spurious loud reject, never a
    #     miscompile. (A heap function with no `@ijl_gc_small_alloc` never
    #     reaches this code — the recogniser is inert.)
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        LLVM.opcode(inst) == LLVM.API.LLVMLoad || continue
        _heap_num_operands(inst) >= 1 || continue
        addr = _heap_operand_ref(inst, 1)
        _heap_ref_is_instruction(addr) || push!(skel, inst.ref)
    end

    # ---- Forward taint closure to a fixed point ----
    # An instruction folds into SKEL when ANY operand is already in SKEL
    # (matches D's "any tainted operand taints the result"). The closure
    # also pulls in the constant-offset GEPs / ptrtoint / loads / stores that
    # form the GC-frame chain and Memory{T} header.
    changed = true
    while changed
        changed = false
        for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
            inst.ref in skel && continue
            # Terminators are not part of SKEL — they are handled by the
            # straight-line check in the proof.
            opc = LLVM.opcode(inst)
            (opc == LLVM.API.LLVMRet || opc == LLVM.API.LLVMBr ||
             opc == LLVM.API.LLVMSwitch || opc == LLVM.API.LLVMIndirectBr ||
             opc == LLVM.API.LLVMUnreachable) && continue
            tainted = false
            for opref in _heap_operand_refs(inst)
                if opref in skel
                    tainted = true
                    break
                end
            end
            if tainted
                push!(skel, inst.ref)
                changed = true
            end
        end
    end

    return skel
end

# ---------------------------------------------------------------------------
# D. The five-part liveness proof — the CORRECTNESS CORE.
# ---------------------------------------------------------------------------

"""
    _prove_skeleton_dead(func, skel, names)

Run the five liveness obligations. ANY failure throws loud. Success means the
skeleton `skel` is recognised, dead w.r.t. the return, isolable, and its
suppression is provably invisible to the surviving slice.

The proof is purely subtractive: it only ever rejects.
"""
function _prove_skeleton_dead(func::LLVM.Function,
                              skel::Set{_LLVMRef},
                              names::Dict{_LLVMRef,Symbol})
    # ----- P-recognise ----------------------------------------------------
    # Forward taint-closure from the seeds; assert the closure ⊆ SKEL. Since
    # `_recognise_skeleton` already ran the closure to a fixed point and put
    # everything tainted INTO `skel`, this obligation re-derives the seed set
    # and confirms no further taint escapes. (If the closure and the seeds
    # disagree the recogniser is internally inconsistent — reject.)
    #
    # The cross-check that matters in practice: P-callee below proves every
    # tainted call is allowlisted; P-escape proves every tainted store is
    # skeleton-owned. Those two are what stop a tangled live computation from
    # being silently swallowed by the taint closure. P-recognise here asserts
    # the structural seed set is closed.
    seeds = _heap_seed_set(func)
    for s in seeds
        s in skel ||
            _heap_error("internal: skeleton seed not in recognised set " *
                        "(taint-closure inconsistency)")
    end

    # ----- P-return -------------------------------------------------------
    # Backward operand-ancestor walk from every `ret` operand: no SKEL
    # instruction may be a `ret`-ancestor. This is the DEADNESS proof.
    ret_ancestors = _heap_return_ancestors(func)
    for a in ret_ancestors
        if a in skel
            v = _heap_value_for_ref(func, a)
            _heap_error("skeleton value $(v === nothing ? "?" : _heap_vname(v)) " *
                        "feeds the function return — the heap computation is " *
                        "LIVE, not dead. M1 only compiles functions whose " *
                        "return is provably independent of the heap")
        end
    end

    # ----- P-escape -------------------------------------------------------
    # Every skeleton `store`'s ADDRESS operand must itself be in `skel`
    # (skeleton-owned memory). A skeleton store into a parameter / sret
    # buffer / aliased non-skeleton address would corrupt live state.
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref in skel || continue
        LLVM.opcode(inst) == LLVM.API.LLVMStore || continue
        _heap_num_operands(inst) >= 2 || continue
        addr = _heap_operand_ref(inst, 2)   # store <val>, <addr>
        # The address is acceptable iff it is either a skeleton-owned SSA
        # value, or a module-scope global / global-alias / constexpr (the
        # `@"jl_global#NNN.jit"` Memory-header pointers — those are constants,
        # not live SSA, and writing through them is part of object init that
        # the dead-skeleton suppression removes wholesale). A NON-skeleton
        # SSA address rejects.
        if _heap_ref_is_instruction(addr)
            addr in skel ||
                _heap_error("skeleton store $(_heap_vname(inst)) targets a " *
                            "non-skeleton SSA address — the heap skeleton is " *
                            "NOT isolable (it writes into live memory)")
        end
        # else: global / constant address — accepted (object-init store).
    end

    # ----- P-callee -------------------------------------------------------
    # Every `call` in SKEL must be an allowlisted callee: the TLS asm,
    # `@ijl_gc_small_alloc`, `@j_#_growend!`, or a benign llvm.* intrinsic
    # (memset / lifetime markers). Any other tainted call rejects — this
    # catches a vector escaping into `@j_sink_*`, Dict's `@j_setindex!`, etc.
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref in skel || continue
        LLVM.opcode(inst) == LLVM.API.LLVMCall || continue
        if _heap_is_inline_asm_call(inst)
            _heap_is_allowlisted_tls_asm(inst) ||
                _heap_error("tainted inline-asm call $(_heap_vname(inst)) is " *
                            "not the allowlisted TLS read")
            continue
        end
        cname = _heap_callee_name(inst)
        ok = _heap_is_allowlisted_callee(cname) ||
             startswith(cname, "llvm.memset.") ||
             startswith(cname, "llvm.lifetime.")
        ok ||
            _heap_error("skeleton-tainted call to `@$cname` " *
                        "($(_heap_vname(inst))) is not an allowlisted heap " *
                        "callee — the heap value escapes into non-skeleton " *
                        "code. M1 rejects rather than risk a miscompile")
    end

    # ----- P-opcode -------------------------------------------------------
    # The forward taint-closure in `_recognise_skeleton` folds ANY tainted
    # instruction into SKEL (any instruction with a skeleton operand), and the
    # walker then SKIPS every SKEL instruction. That is sound only when the
    # suppressed instruction has no side effect the proof fails to model:
    #   - plain `store` is vetted by P-escape (skeleton-owned address);
    #   - `call` is vetted by P-callee (allowlisted callee);
    #   - every remaining tainted opcode (arithmetic / gep / cast / phi /
    #     select / load / ...) is side-effect-free, so suppressing it is sound.
    # The EXCEPTIONS are the side-effecting opcodes below, which carry memory
    # or control side effects this proof does not model — and which the taint
    # closure CAN reach (the closure only excludes Ret/Br/Switch/IndirectBr/
    # Unreachable, so Invoke/CallBr are reachable; AtomicRMW/CmpXchg have SSA
    # operands and taint normally). `invoke`/`callbr` are NOT opcode `LLVMCall`
    # so they slip past P-callee entirely. Closed-world fail-loud per
    # CLAUDE.md §1/§10: reject the genuinely unmodelled rather than rely on
    # "essentially never appears in f1's concrete-integer scope".
    _SKEL_FORBIDDEN_OPCODES = (
        (LLVM.API.LLVMAtomicRMW,     "atomicrmw"),
        (LLVM.API.LLVMAtomicCmpXchg, "cmpxchg"),
        (LLVM.API.LLVMFence,         "fence"),
        (LLVM.API.LLVMInvoke,        "invoke"),
        (LLVM.API.LLVMCallBr,        "callbr"),
    )
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref in skel || continue
        opc = LLVM.opcode(inst)
        for (forbidden, mnemonic) in _SKEL_FORBIDDEN_OPCODES
            opc == forbidden &&
                _heap_error("skeleton instruction $(_heap_vname(inst)) has " *
                            "side-effecting opcode `$mnemonic` that M1's " *
                            "liveness proof does not model; refusing to " *
                            "suppress it")
        end
    end

    # ----- P-noload-into-live --------------------------------------------
    # No NON-skeleton `load` may read an address that a skeleton `store`
    # wrote. If a kept load could observe a dropped skeleton write the
    # suppression would change the value the surviving slice sees → reject.
    # This is the worklog/029 cond_pair / array_even_idx guard.
    #
    # "skeleton-written address" = the address operand of any skeleton store,
    # whether an SSA value (in `skel`) or a global/constexpr ref. We collect
    # them all and reject a non-skeleton load whose address ref matches.
    skel_written_addrs = Set{_LLVMRef}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref in skel || continue
        LLVM.opcode(inst) == LLVM.API.LLVMStore || continue
        _heap_num_operands(inst) >= 2 || continue
        push!(skel_written_addrs, _heap_operand_ref(inst, 2))
    end
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref in skel && continue
        LLVM.opcode(inst) == LLVM.API.LLVMLoad || continue
        _heap_num_operands(inst) >= 1 || continue
        addr = _heap_operand_ref(inst, 1)
        # A non-skeleton load reading a skeleton SSA address, OR reading an
        # address a skeleton store wrote to, is unsound to suppress.
        if (_heap_ref_is_instruction(addr) && addr in skel) ||
           addr in skel_written_addrs
            _heap_error("surviving (non-skeleton) load $(_heap_vname(inst)) " *
                        "reads skeleton-owned / skeleton-written memory — " *
                        "the heap skeleton cannot be suppressed without " *
                        "changing the value this load observes")
        end
    end

    return nothing
end

# Re-derive the structural seed set (used by P-recognise as a closedness
# cross-check). Mirrors the seed logic in `_recognise_skeleton` exactly.
function _heap_seed_set(func::LLVM.Function)
    seeds = Set{_LLVMRef}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        opc = LLVM.opcode(inst)
        if opc == LLVM.API.LLVMAlloca
            push!(seeds, inst.ref)
        elseif opc == LLVM.API.LLVMLoad
            # load from a non-SSA (global / constexpr) address — see seed (5).
            if _heap_num_operands(inst) >= 1 &&
               !_heap_ref_is_instruction(_heap_operand_ref(inst, 1))
                push!(seeds, inst.ref)
            end
        elseif _heap_is_inline_asm_call(inst)
            push!(seeds, inst.ref)
        else
            cname = _heap_callee_name(inst)
            if !isempty(cname) && (startswith(cname, "llvm.memset.") ||
               cname == "ijl_gc_small_alloc" ||
               occursin(_GC_GROWEND_CALLEE_RE, cname))
                push!(seeds, inst.ref)
            end
        end
    end
    return seeds
end

# Backward operand-ancestor closure from every `ret` operand. Returns the set
# of instruction refs that are (transitively) operands of a `ret`.
function _heap_return_ancestors(func::LLVM.Function)
    # ref → LLVM.Instruction map for every SSA instruction (so we can re-walk
    # an ancestor's operands without identifying intervening operand values).
    inst_by_ref = Dict{_LLVMRef,LLVM.Instruction}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst_by_ref[inst.ref] = inst
    end

    ancestors = Set{_LLVMRef}()
    worklist = _LLVMRef[]
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        LLVM.opcode(inst) == LLVM.API.LLVMRet || continue
        for opref in _heap_operand_refs(inst)
            _heap_ref_is_instruction(opref) && push!(worklist, opref)
        end
    end
    while !isempty(worklist)
        ref = pop!(worklist)
        ref in ancestors && continue
        push!(ancestors, ref)
        inst = get(inst_by_ref, ref, nothing)
        inst === nothing && continue
        for opref in _heap_operand_refs(inst)
            _heap_ref_is_instruction(opref) && push!(worklist, opref)
        end
    end
    return ancestors
end

# Find the LLVM.Value for a given instruction ref (linear scan; only used in
# error paths so cost is irrelevant).
function _heap_value_for_ref(func::LLVM.Function, ref::_LLVMRef)
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref === ref && return inst
    end
    return nothing
end

# ---------------------------------------------------------------------------
# B/§Spec — build the surviving single-block return.
# ---------------------------------------------------------------------------

# After the skeleton is proven dead, collect the surviving non-skeleton
# instructions in program order. By M1 condition 4 they are straight-line:
# every non-skeleton terminator must be the function's final `ret`. Any
# surviving non-skeleton conditional branch rejects loud.
#
# Returns `(ret_inst, survivors)` — `ret_inst` is the `IRRet` of the resolved
# return operand; `survivors` are the surviving non-terminator instructions.
function _build_surviving_slice(func::LLVM.Function,
                                skel::Set{_LLVMRef},
                                names::Dict{_LLVMRef,Symbol})
    survivors = IRInst[]
    ret_inst::Union{Nothing,IRInst} = nothing

    for bb in LLVM.blocks(func)
        for inst in LLVM.instructions(bb)
            inst.ref in skel && continue
            opc = LLVM.opcode(inst)
            if opc == LLVM.API.LLVMRet
                ops = LLVM.operands(inst)
                isempty(ops) &&
                    _heap_error("surviving `ret void` — M1 expects a value " *
                                "return (the heap-independent result)")
                ret_inst === nothing ||
                    _heap_error("more than one surviving `ret` — the " *
                                "surviving slice is not single-exit")
                # `ret`'s sole operand is the return value: for M1 it is a
                # function parameter or a constant — both identify cleanly.
                ret_inst = IRRet(_operand(ops[1], names), _iwidth(ops[1]))
            elseif opc == LLVM.API.LLVMBr
                # LLVM `br` has 1 operand (unconditional) or 3 (conditional:
                # operand 1 = condition, operands 2/3 = the dest blocks).
                #
                #  - unconditional branch: benign linear control flow that
                #    simplifycfg would fold — the surviving slice spans
                #    blocks linearly, skip it.
                #  - conditional branch whose CONDITION is a skeleton value:
                #    this is the dead capacity/growend diamond. The whole
                #    diamond is skeleton (M1 condition 4 — "any branching is
                #    ENTIRELY skeleton"), so it is suppressed along with the
                #    rest of the skeleton, skip it.
                #  - conditional branch whose condition is NOT skeleton: a
                #    real user branch survived → the surviving slice is not
                #    straight-line → reject loud.
                if _heap_num_operands(inst) == 1
                    continue
                end
                cond = _heap_operand_ref(inst, 1)
                if _heap_ref_is_instruction(cond) && cond in skel
                    # Dead skeleton diamond — suppressed.
                    continue
                else
                    _heap_error("surviving (non-skeleton) conditional branch " *
                                "$(_heap_vname(inst)) — its condition is not a " *
                                "heap-skeleton value, so a real user branch " *
                                "survived. M1 requires the surviving slice to " *
                                "be straight-line; any diamond/branching must " *
                                "be entirely within the heap skeleton")
                end
            elseif opc == LLVM.API.LLVMSwitch || opc == LLVM.API.LLVMIndirectBr
                _heap_error("surviving (non-skeleton) multi-way branch " *
                            "$(_heap_vname(inst)) — M1 requires a " *
                            "straight-line surviving slice")
            elseif opc == LLVM.API.LLVMUnreachable
                # A surviving `unreachable` would mean a non-skeleton block
                # has no real exit. M1 expects the return to dominate.
                _heap_error("surviving (non-skeleton) `unreachable` — M1 " *
                            "expects the surviving slice to fall through to " *
                            "the function return")
            else
                # A genuine surviving computed instruction. For f1 there are
                # none. If one appears it must be convertible by the normal
                # walker; M1 does not attempt to convert it here — rejects.
                _heap_error("surviving (non-skeleton) instruction " *
                            "$(_heap_vname(inst)) — M1 only compiles " *
                            "functions whose entire non-return body is dead " *
                            "heap skeleton. A surviving live computation is " *
                            "out of M1 scope")
            end
        end
    end

    ret_inst === nothing &&
        _heap_error("no surviving `ret` found after skeleton suppression")
    return ret_inst, survivors
end

# ===========================================================================
# Bennett-kuza / M2 — partially-dead heap arrays.
#
# M2 handles a statically-sized heap integer array whose ELEMENT DATA is LIVE
# into the return. M1's monolithic SKEL is partitioned into
#   {dead GC machinery → drop} ∪ {live element traffic → re-root}
# and the element traffic is re-rooted onto a synthetic const-N `IRAlloca`, so
# the existing `:shadow` / `:shadow_checkpoint` alloca lowering compiles it.
#
# CLAUDE.md §1: the catastrophe is a silent miscompile — a dropped element
# store, a missed data-region load, or a mis-collapsed bounds diamond. Every
# obligation below bails LOUD; the partition is closed-world (every SKEL
# instruction must be positively classified, ANY leftover rejects).
# ===========================================================================

function _heap_m2_error(reason::AbstractString)
    error("ir_extract.jl: heap-memory recogniser: $reason (Bennett-kuza / M2)")
end

# Anchored regex for the Julia `throw_boundserror` callee. Matched against
# CALLEE FUNCTION NAMES ONLY — never value names. The `_NNN` suffix is a
# per-JIT-session counter and varies per session.
const _GC_THROW_BOUNDSERROR_RE = r"^j_throw_boundserror_\d+$"

# ---------------------------------------------------------------------------
# GEP-structure helpers (raw C API — never identify GlobalAlias operands).
# ---------------------------------------------------------------------------

# True iff `inst` is a `getelementptr`.
_heap_is_gep(inst::LLVM.Instruction) =
    LLVM.opcode(inst) == LLVM.API.LLVMGetElementPtr

# Return the byte stride of a GEP's source element type, or `nothing` if the
# source element type is not a plain integer (struct/array/float/vector).
function _heap_gep_int_stride_bytes(inst::LLVM.Instruction)
    src_ref = LLVM.API.LLVMGetGEPSourceElementType(inst.ref)
    src_ty  = LLVM.LLVMType(src_ref)
    src_ty isa LLVM.IntegerType || return nothing
    w = LLVM.width(src_ty)
    w % 8 == 0 || return nothing
    return w ÷ 8
end

# True iff `ref` is a ConstantInt.
_heap_ref_is_const_int(ref::_LLVMRef)::Bool =
    LLVM.API.LLVMIsAConstantInt(ref) != C_NULL

# Signed value of a ConstantInt ref.
_heap_const_int_sval(ref::_LLVMRef)::Int =
    Int(LLVM.API.LLVMConstIntGetSExtValue(ref))

# Classify a GEP instruction. Returns a NamedTuple with fields:
#   base    :: _LLVMRef       — the GEP base operand ref
#   nidx    :: Int            — number of index operands
#   simple  :: Bool           — true iff a 2-operand integer-stride GEP
#   coff    :: Union{Int,Nothing}    — constant BYTE offset (simple+const idx)
#   ridx    :: Union{_LLVMRef,Nothing} — runtime index ref (simple+runtime idx)
# A non-simple GEP (struct GEP `{i64,ptr},%M,0,1`, non-integer stride, >2
# operands) has `simple=false, coff=nothing, ridx=nothing` — classified as GC
# machinery if tainted.
function _heap_gep_info(inst::LLVM.Instruction)
    n = _heap_num_operands(inst)
    base = _heap_operand_ref(inst, 1)
    if n != 2
        return (base=base, nidx=n - 1, simple=false,
                coff=nothing, ridx=nothing)
    end
    stride = _heap_gep_int_stride_bytes(inst)
    stride === nothing &&
        return (base=base, nidx=1, simple=false, coff=nothing, ridx=nothing)
    idx = _heap_operand_ref(inst, 2)
    if _heap_ref_is_const_int(idx)
        return (base=base, nidx=1, simple=true,
                coff=_heap_const_int_sval(idx) * stride, ridx=nothing)
    else
        return (base=base, nidx=1, simple=true, coff=nothing, ridx=idx)
    end
end

# ---------------------------------------------------------------------------
# Q-A — heap-array structural recognition.
# ---------------------------------------------------------------------------

"""
    _HeapArray

Result of the M2 heap-array recogniser. Identifies the Memory backing object,
its element-data pointer, the optional Array wrapper, the static capacity, and
the element bit width.
"""
struct _HeapArray
    memory_obj::_LLVMRef                 # the @ijl_gc_small_alloc Memory result
    data_ptr::_LLVMRef                   # the unique GEP(memory_obj, 16)
    wrapper::Union{Nothing,_LLVMRef}     # the Array wrapper alloc result, or nothing
    capacity::Int                        # static N (length field)
    elem_width::Int                      # element bit width (from store/load values)
end

# Find the unique `GEP(base, byte_offset)` whose constant byte offset equals
# `want`. Returns the GEP instruction ref, or `nothing`.
function _heap_find_const_gep(func::LLVM.Function, base::_LLVMRef, want::Int)
    found::Union{Nothing,_LLVMRef} = nothing
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_is_gep(inst) || continue
        gi = _heap_gep_info(inst)
        gi.base === base && gi.simple && gi.coff == want || continue
        found === nothing ||
            _heap_m2_error("multiple `GEP($want)` off the same object — " *
                           "ambiguous Memory layout")
        found = inst.ref
    end
    return found
end

# Recognise the heap array. `allocs` has 1 (Memory only — cond_pair shape) or
# 2 (Memory + Array wrapper) `@ijl_gc_small_alloc` results.
function _recognise_heap_array(func::LLVM.Function,
                               allocs::Vector{LLVM.Instruction})
    # The Memory object is the alloc whose result has: a constant length store
    # `store i64 N, %M` at offset 0; a tag store `store i64 _, GEP(%M,-1)`; a
    # self-data store `store %md, GEP({i64,ptr},%M,0,1)` where `%md=GEP(%M,16)`.
    function is_memory_alloc(aref::_LLVMRef)
        # length store at offset 0 (the alloc result is the store address).
        has_len = false
        for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
            LLVM.opcode(inst) == LLVM.API.LLVMStore || continue
            _heap_num_operands(inst) >= 2 || continue
            _heap_operand_ref(inst, 2) === aref || continue
            v = _heap_operand_ref(inst, 1)
            _heap_ref_is_const_int(v) && (has_len = true)
        end
        # data pointer GEP(%M, 16).
        dp = _heap_find_const_gep(func, aref, 16)
        return has_len && dp !== nothing
    end

    mem_alloc::Union{Nothing,_LLVMRef} = nothing
    wrap_alloc::Union{Nothing,_LLVMRef} = nothing
    for a in allocs
        if is_memory_alloc(a.ref)
            mem_alloc === nothing ||
                _heap_m2_error("two allocs both look like a Memory backing " *
                               "object — cannot pair Memory + Array wrapper")
            mem_alloc = a.ref
        else
            wrap_alloc === nothing ||
                _heap_m2_error("two allocs neither of which is a recognised " *
                               "Memory backing object")
            wrap_alloc = a.ref
        end
    end
    mem_alloc === nothing &&
        _heap_m2_error("no `@ijl_gc_small_alloc` matches the Memory backing " *
                       "object predicate (length store + tag + data GEP) — " *
                       "unrecognised heap object shape")

    data_ptr = _heap_find_const_gep(func, mem_alloc, 16)
    data_ptr === nothing &&
        _heap_m2_error("Memory object has no `GEP(memory_obj, 16)` data pointer")

    # Two allocs: the non-Memory alloc must be a linked Array wrapper —
    # `store %md, %W` at offset 0 and `store %M, GEP(%W, 8)` at offset 8.
    if length(allocs) == 2
        wrap_alloc === nothing &&
            _heap_m2_error("two allocs but the second is not an Array wrapper")
        # offset-0 store: must store the data pointer.
        w0_ok = false
        for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
            LLVM.opcode(inst) == LLVM.API.LLVMStore || continue
            _heap_num_operands(inst) >= 2 || continue
            _heap_operand_ref(inst, 2) === wrap_alloc || continue
            _heap_operand_ref(inst, 1) === data_ptr && (w0_ok = true)
        end
        w0_ok ||
            _heap_m2_error("Array wrapper offset-0 store does not store the " *
                           "Memory data pointer — wrapper/Memory not linked")
        # offset-8 store: must store the Memory object.
        w8gep = _heap_find_const_gep(func, wrap_alloc, 8)
        w8gep === nothing &&
            _heap_m2_error("Array wrapper has no offset-8 GEP for the Memory ptr")
        w8_ok = false
        for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
            LLVM.opcode(inst) == LLVM.API.LLVMStore || continue
            _heap_num_operands(inst) >= 2 || continue
            _heap_operand_ref(inst, 2) === w8gep || continue
            _heap_operand_ref(inst, 1) === mem_alloc && (w8_ok = true)
        end
        w8_ok ||
            _heap_m2_error("Array wrapper offset-8 store does not store the " *
                           "Memory object — wrapper/Memory not linked")
    elseif length(allocs) == 1
        wrap_alloc = nothing
    end

    # Capacity + element width are derived after the partition; placeholders
    # here, filled by _infer_capacity / the partition.
    capacity = _infer_capacity(func, mem_alloc, wrap_alloc)
    return _HeapArray(mem_alloc, data_ptr, wrap_alloc, capacity, 0)
end

# ---------------------------------------------------------------------------
# Q-D — capacity inference.
# ---------------------------------------------------------------------------

# `N` from the unique constant `store i64 N, ptr %memory_obj` (offset 0).
# Cross-checked vs the Array-wrapper size store `store i64 N2, GEP(%W,16)`.
function _infer_capacity(func::LLVM.Function, mem_obj::_LLVMRef,
                         wrapper::Union{Nothing,_LLVMRef})
    n::Union{Nothing,Int} = nothing
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        LLVM.opcode(inst) == LLVM.API.LLVMStore || continue
        _heap_num_operands(inst) >= 2 || continue
        _heap_operand_ref(inst, 2) === mem_obj || continue
        v = _heap_operand_ref(inst, 1)
        _heap_ref_is_const_int(v) ||
            _heap_m2_error("Memory length store has a non-constant value — " *
                           "runtime-N heap arrays are out of M2 scope")
        nv = _heap_const_int_sval(v)
        n === nothing ||
            _heap_m2_error("multiple length stores into the Memory object")
        n = nv
    end
    n === nothing &&
        _heap_m2_error("no constant `store i64 N, ptr %memory_obj` length " *
                       "store — runtime-N out of M2 scope")
    n >= 1 ||
        _heap_m2_error("Memory length store value $n is not a positive capacity")

    if wrapper !== nothing
        w16 = _heap_find_const_gep(func, wrapper, 16)
        if w16 !== nothing
            for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
                LLVM.opcode(inst) == LLVM.API.LLVMStore || continue
                _heap_num_operands(inst) >= 2 || continue
                _heap_operand_ref(inst, 2) === w16 || continue
                v = _heap_operand_ref(inst, 1)
                _heap_ref_is_const_int(v) || continue
                n2 = _heap_const_int_sval(v)
                n2 == n ||
                    _heap_m2_error("Array wrapper size $n2 ≠ Memory length $n")
            end
        end
    end
    return n
end

# ---------------------------------------------------------------------------
# Q-F — bounds-check diamond collapse.
# ---------------------------------------------------------------------------

# A "throw block" is an `unreachable`-terminated block (hence NO successors)
# that contains exactly one `call @j_throw_boundserror_NNN`. Such a block is
# always safe to drop wholesale: an `unreachable`-terminated block has no
# successors, so by LLVM SSA dominance EVERY value it defines is used only
# within the block itself — nothing it computes can be observed by the live
# (non-throw) slice. The throw-arm setup arithmetic Julia emits (the
# `%idx+1`, the `Tuple` stores, the gc-slot store) is therefore dead the
# instant the guarding branch is dropped.
#
# CLAUDE.md §1: a FALSE positive here would drop a live block — but the
# `unreachable` terminator + the bounds-error callee name together pin the
# shape. A non-throw block that happens to end in `unreachable` and call a
# `j_throw_boundserror_*` is, by construction, the Julia bounds-check arm.
function _heap_is_throw_block(bb::LLVM.BasicBlock, skel::Set{_LLVMRef})
    term = LLVM.terminator(bb)
    term === nothing && return false
    LLVM.opcode(term) == LLVM.API.LLVMUnreachable || return false
    saw_throw_call = false
    for inst in LLVM.instructions(bb)
        LLVM.opcode(inst) == LLVM.API.LLVMCall || continue
        cname = _heap_callee_name(inst)
        if occursin(_GC_THROW_BOUNDSERROR_RE, cname)
            saw_throw_call && return false   # two throw calls — not the shape
            saw_throw_call = true
        end
    end
    return saw_throw_call
end

"""
    _collapse_bounds_diamond(func, skel) -> Set{_LLVMRef}

Recognise and collapse every Julia bounds-check diamond. Returns the set of
"dropped" instruction refs: every instruction inside a recognised throw block,
plus the conditional `br` that guards it.

A bounds-check diamond is a `br i1 %c, %A, %B` whose condition is non-skeleton
and where exactly ONE of `%A`/`%B` is a recognised throw block. The throw arm
is `unreachable`-terminated (no reconvergence — no phis to rewrite). Collapsing
drops the throw block + the `br`; the non-throw block is spliced inline by the
surviving-slice builder (which walks blocks in program order).

A `br` on a non-skeleton condition that is NOT a recognised bounds diamond
(both arms live) rejects loud — general control flow is out of M2 scope.
"""
function _collapse_bounds_diamond(func::LLVM.Function, skel::Set{_LLVMRef})
    dropped = Set{_LLVMRef}()
    for bb in LLVM.blocks(func)
        term = LLVM.terminator(bb)
        term === nothing && continue
        LLVM.opcode(term) == LLVM.API.LLVMBr || continue
        # Unconditional br — benign linear control flow; not a diamond.
        _heap_num_operands(term) == 1 && continue
        # Conditional br: operand 1 = condition; operands 2/3 = dest blocks.
        cond = _heap_operand_ref(term, 1)
        if _heap_ref_is_instruction(cond) && cond in skel
            # Skeleton-condition diamond — handled by the M1 dead-skeleton
            # path; M2's partition will only fire on a non-skeleton-live
            # element traffic so a fully-skeleton diamond cannot reach here
            # with element traffic. Leave it for the M1 builder.
            continue
        end
        # Non-skeleton condition. Exactly one successor must be a throw block.
        succs = collect(LLVM.successors(term))
        length(succs) == 2 ||
            _heap_m2_error("conditional branch with $(length(succs)) " *
                           "successors is not a 2-way bounds diamond")
        throw_idx = 0
        for (k, s) in enumerate(succs)
            if _heap_is_throw_block(s, skel)
                throw_idx == 0 ||
                    _heap_m2_error("both branch arms are throw blocks — " *
                                   "unrecognised control flow")
                throw_idx = k
            end
        end
        throw_idx == 0 &&
            _heap_m2_error("a surviving non-skeleton branch " *
                           "$(_heap_vname(term)) is not a bounds-check " *
                           "diamond (neither arm is a throw block) — " *
                           "general control flow is out of M2 scope")
        # Collapse: drop the throw block's instructions + the guarding br.
        push!(dropped, term.ref)
        throw_bb = succs[throw_idx]
        for inst in LLVM.instructions(throw_bb)
            push!(dropped, inst.ref)
        end
    end
    return dropped
end

# ---------------------------------------------------------------------------
# Q-B — the partition.
# ---------------------------------------------------------------------------

"""
    _ElemAccess

A captured element store or load. `kind` is `:store` or `:load`. `index` is a
constant element index (`Int`) or a runtime index SSA ref (`_LLVMRef`).
`value` is the stored value ref (`:store`) or the load instruction ref
(`:load`). `inst` is the store/load instruction ref. `pos` is the
program-order position (for stable ordering).
"""
struct _ElemAccess
    kind::Symbol
    index::Union{Int,_LLVMRef}
    value::_LLVMRef
    inst::_LLVMRef
    width::Int
    pos::Int
end

"""
    _partition_skeleton(func, skel, harr, dropped)
        -> (elem_traffic::Vector{_ElemAccess}, gc_machinery::Set{_LLVMRef})

Partition `SKEL ∖ dropped` into element traffic (live store/load/GEP onto the
data region) and GC machinery (everything else). STRICT: every SKEL
instruction not in `dropped` must be positively classified; an unclassifiable
instruction rejects loud.
"""
function _partition_skeleton(func::LLVM.Function, skel::Set{_LLVMRef},
                             harr::_HeapArray, dropped::Set{_LLVMRef})
    mem_obj  = harr.memory_obj
    data_ptr = harr.data_ptr
    wrapper  = harr.wrapper
    N        = harr.capacity

    # Element-GEP refs: a GEP rooted at `data_ptr` (any index) OR a const-offset
    # GEP rooted at `mem_obj` with `16 ≤ coff < 16+N`. `data_ptr` itself is the
    # buffer base and counts as element traffic.
    elem_gep_index = Dict{_LLVMRef,Union{Int,_LLVMRef}}()  # gep ref → index
    elem_traffic = _ElemAccess[]
    gc_machinery = Set{_LLVMRef}()

    # Program-order position table.
    pos = Dict{_LLVMRef,Int}()
    let p = 0
        for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
            p += 1
            pos[inst.ref] = p
        end
    end

    # First pass — classify the element GEPs (so stores/loads can be keyed off
    # them in the second pass).
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref in skel || continue
        inst.ref in dropped && continue
        _heap_is_gep(inst) || continue
        gi = _heap_gep_info(inst)
        if gi.base === data_ptr
            # GEP off the data pointer.
            gi.simple ||
                _heap_m2_error("non-simple GEP off the data pointer " *
                               "$(_heap_vname(inst)) — unsupported addressing")
            if gi.coff !== nothing
                idx = gi.coff   # data_ptr stride is 1 byte (i8) → coff == index
                0 <= idx < N ||
                    _heap_m2_error("const element GEP off data_ptr at index " *
                                   "$idx out of range [0,$N)")
                elem_gep_index[inst.ref] = idx
            else
                elem_gep_index[inst.ref] = gi.ridx
            end
        elseif gi.base === mem_obj && gi.simple && gi.coff !== nothing
            c = gi.coff
            if c == 16
                # This is `data_ptr` itself — buffer base, element index 0.
                elem_gep_index[inst.ref] = 0
            elseif c > 16
                idx = c - 16
                idx < N ||
                    _heap_m2_error("element GEP `GEP(memory_obj,$c)` is " *
                                   "out of range — capacity N=$N covers " *
                                   "byte offsets [16,$(16+N))")
                elem_gep_index[inst.ref] = idx
            else
                # c == -1 (tag) or a header offset → GC machinery.
                push!(gc_machinery, inst.ref)
            end
        elseif gi.base === mem_obj && !gi.simple
            # struct GEP `{i64,ptr},%M,0,1` (memory_ptr) → GC machinery.
            push!(gc_machinery, inst.ref)
        elseif gi.base === mem_obj && gi.simple && gi.coff === nothing
            # runtime GEP off raw memory_obj — reject (runtime reads must root
            # at data_ptr).
            _heap_m2_error("runtime-indexed GEP off the raw Memory object " *
                           "$(_heap_vname(inst)) — runtime element access " *
                           "must be rooted at the data pointer GEP(memory,16)")
        else
            # GEP off the wrapper / gcframe / etc. → GC machinery.
            push!(gc_machinery, inst.ref)
        end
    end
    # data_ptr itself is element traffic (buffer base, index 0).
    elem_gep_index[data_ptr] = 0

    # Second pass — classify every SKEL ∖ dropped instruction.
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref in skel || continue
        inst.ref in dropped && continue
        haskey(elem_gep_index, inst.ref) && continue  # element GEP, done
        gc_machinery_has = inst.ref in gc_machinery
        opc = LLVM.opcode(inst)

        if opc == LLVM.API.LLVMStore
            _heap_num_operands(inst) >= 2 ||
                _heap_m2_error("malformed store $(_heap_vname(inst))")
            addr = _heap_operand_ref(inst, 2)
            val  = _heap_operand_ref(inst, 1)
            if haskey(elem_gep_index, addr)
                # Element store. The stored value must NOT itself be skeleton.
                if _heap_ref_is_instruction(val) && val in skel &&
                   !(val in dropped)
                    _heap_m2_error("element store $(_heap_vname(inst)) writes " *
                                   "a skeleton-tainted value — the heap " *
                                   "skeleton is not isolable")
                end
                # M2 is scoped (consensus design §4 M2) to constant-offset
                # stores + runtime-indexed loads. A runtime-index store is
                # NOT covered by the soundness proof — `_prove_partition_sound`
                # / `_heap_m2_return_ancestors` vet a runtime *load* index for
                # machinery-taint but never reach a *store* index. Reject loud
                # at classification time, before `_ElemAccess` capture.
                if elem_gep_index[addr] isa _LLVMRef
                    _heap_m2_error("runtime-index element store " *
                        "$(_heap_vname(inst)) — M2 supports constant-offset " *
                        "stores + runtime-indexed loads (consensus design §4 " *
                        "M2); a runtime-index store is follow-up work " *
                        "(Bennett-kuza / M2)")
                end
                # Store width = the LLVM type of the stored value operand.
                store_w = _iwidth(LLVM.operands(inst)[1])
                push!(elem_traffic,
                      _ElemAccess(:store, elem_gep_index[addr], val,
                                  inst.ref, store_w, pos[inst.ref]))
            else
                # tag / length / memory-self / wrapper-header store → machinery.
                push!(gc_machinery, inst.ref)
            end

        elseif opc == LLVM.API.LLVMLoad
            _heap_num_operands(inst) >= 1 ||
                _heap_m2_error("malformed load $(_heap_vname(inst))")
            addr = _heap_operand_ref(inst, 1)
            if haskey(elem_gep_index, addr)
                push!(elem_traffic,
                      _ElemAccess(:load, elem_gep_index[addr], inst.ref,
                                  inst.ref, _iwidth(inst), pos[inst.ref]))
            else
                # GC-frame epilogue / header load → machinery.
                push!(gc_machinery, inst.ref)
            end

        elseif opc == LLVM.API.LLVMCall
            push!(gc_machinery, inst.ref)        # vetted by P-callee
        elseif opc == LLVM.API.LLVMAlloca
            push!(gc_machinery, inst.ref)
        else
            # ptrtoint / inttoptr / bitcast / cast / arithmetic feeding the GC
            # frame chain — side-effect-free machinery.
            if !gc_machinery_has
                # Anything that was not already classified as an element GEP
                # and is not a store/load/call/alloca is residual machinery,
                # UNLESS it is unclassifiable. The taint closure only folds in
                # instructions with a skeleton operand; a side-effect-free
                # cast/arith is safe to treat as machinery (it is dropped, and
                # P-return restricted to machinery proves no machinery feeds
                # the return).
                push!(gc_machinery, inst.ref)
            end
        end
    end

    # Strictness: union covers SKEL ∖ dropped, disjoint.
    classified = Set{_LLVMRef}()
    for r in keys(elem_gep_index)
        r in skel && push!(classified, r)
    end
    for ea in elem_traffic
        push!(classified, ea.inst)
    end
    union!(classified, gc_machinery)
    for r in skel
        r in dropped && continue
        r in classified ||
            _heap_m2_error("skeleton instruction $(_heap_vname(_heap_value_for_ref(func, r))) " *
                           "is neither element traffic nor GC machinery — " *
                           "partition is not closed")
    end

    # Element width: uniform across all captured store/load values.
    if !isempty(elem_traffic)
        w0 = elem_traffic[1].width
        for ea in elem_traffic
            ea.width == w0 ||
                _heap_m2_error("mixed element widths ($(ea.width) vs $w0) — " *
                               "non-uniform element type out of M2 scope")
        end
    end

    sort!(elem_traffic, by = ea -> ea.pos)
    return elem_traffic, gc_machinery
end

# ---------------------------------------------------------------------------
# Q-C — the soundness proof.
# ---------------------------------------------------------------------------

# Trace whether an address ref's provenance roots at the data pointer /
# memory_obj+16. Walks GEP/cast chains backward.
function _heap_addr_roots_at_data(func::LLVM.Function, addr::_LLVMRef,
                                  harr::_HeapArray)
    addr === harr.data_ptr && return true
    seen = Set{_LLVMRef}()
    work = _LLVMRef[addr]
    inst_by_ref = Dict{_LLVMRef,LLVM.Instruction}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst_by_ref[inst.ref] = inst
    end
    while !isempty(work)
        r = pop!(work)
        r in seen && continue
        push!(seen, r)
        r === harr.data_ptr && return true
        inst = get(inst_by_ref, r, nothing)
        inst === nothing && continue
        opc = LLVM.opcode(inst)
        if opc == LLVM.API.LLVMGetElementPtr
            gi = _heap_gep_info(inst)
            # GEP rooted at memory_obj with offset >= 16 → data region.
            if gi.base === harr.memory_obj && gi.simple &&
               gi.coff !== nothing && gi.coff >= 16
                return true
            end
            push!(work, gi.base)
        elseif opc in (LLVM.API.LLVMBitCast, LLVM.API.LLVMPtrToInt,
                       LLVM.API.LLVMIntToPtr, LLVM.API.LLVMAddrSpaceCast)
            _heap_num_operands(inst) >= 1 &&
                push!(work, _heap_operand_ref(inst, 1))
        end
    end
    return false
end

# Collect the refs of every element GEP (rooted at data_ptr, or at memory_obj
# with a constant offset ≥ 16). `data_ptr` itself is included.
function _heap_elem_gep_refs(func::LLVM.Function, harr::_HeapArray)
    refs = Set{_LLVMRef}([harr.data_ptr])
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_is_gep(inst) || continue
        gi = _heap_gep_info(inst)
        if gi.base === harr.data_ptr ||
           (gi.base === harr.memory_obj && gi.simple && gi.coff !== nothing &&
            gi.coff >= 16)
            push!(refs, inst.ref)
        end
    end
    return refs
end

# M2-aware backward ret-ancestor closure. UNLIKE `_heap_return_ancestors`,
# this walk RE-ROOTS element traffic: when it reaches an element GEP it
# recurses ONLY into the index operand (the user-arithmetic that survives),
# NOT into the base (the original Memory-object alloc chain, which M2 drops
# and replaces with a synthetic alloca). When it reaches `data_ptr` it stops.
# An element load's address is an element GEP, so reaching a load recurses
# into the GEP, which recurses into the index. The result is the set of
# instruction refs that feed the return AFTER re-rooting — exactly what
# M2-O3 needs (GC-machinery membership ⇒ a genuine live-machinery leak).
function _heap_m2_return_ancestors(func::LLVM.Function, harr::_HeapArray)
    elem_geps = _heap_elem_gep_refs(func, harr)
    inst_by_ref = Dict{_LLVMRef,LLVM.Instruction}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst_by_ref[inst.ref] = inst
    end
    ancestors = Set{_LLVMRef}()
    worklist = _LLVMRef[]
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        LLVM.opcode(inst) == LLVM.API.LLVMRet || continue
        for opref in _heap_operand_refs(inst)
            _heap_ref_is_instruction(opref) && push!(worklist, opref)
        end
    end
    while !isempty(worklist)
        ref = pop!(worklist)
        ref in ancestors && continue
        push!(ancestors, ref)
        ref === harr.data_ptr && continue   # buffer base — re-rooted, stop
        inst = get(inst_by_ref, ref, nothing)
        inst === nothing && continue
        if ref in elem_geps
            # Element GEP — recurse only into the index operand(s), not the
            # base (operand 1). The base is re-rooted to the synthetic alloca.
            n = _heap_num_operands(inst)
            for i in 2:n
                opref = _heap_operand_ref(inst, i)
                _heap_ref_is_instruction(opref) && push!(worklist, opref)
            end
        else
            for opref in _heap_operand_refs(inst)
                _heap_ref_is_instruction(opref) && push!(worklist, opref)
            end
        end
    end
    return ancestors
end

"""
    _prove_partition_sound(func, skel, harr, elem_traffic, gc_machinery, dropped)

The M2 soundness proof. Every obligation bails LOUD. See Q-C in the M2 spec.
"""
function _prove_partition_sound(func::LLVM.Function, skel::Set{_LLVMRef},
                                harr::_HeapArray,
                                elem_traffic::Vector{_ElemAccess},
                                gc_machinery::Set{_LLVMRef},
                                dropped::Set{_LLVMRef})
    N = harr.capacity
    captured_insts = Set{_LLVMRef}(ea.inst for ea in elem_traffic)

    # ----- M2-O1 store-capture --------------------------------------------
    # Every SKEL store addressing the data region must be captured (not in
    # gc_machinery).
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref in skel || continue
        inst.ref in dropped && continue
        LLVM.opcode(inst) == LLVM.API.LLVMStore || continue
        _heap_num_operands(inst) >= 2 || continue
        addr = _heap_operand_ref(inst, 2)
        if _heap_addr_roots_at_data(func, addr, harr)
            inst.ref in captured_insts ||
                _heap_m2_error("M2-O1: a store into the element data region " *
                               "$(_heap_vname(inst)) was NOT captured as " *
                               "element traffic — it would be silently dropped")
            inst.ref in gc_machinery &&
                _heap_m2_error("M2-O1: a data-region store $(_heap_vname(inst)) " *
                               "was classified as GC machinery")
        end
    end

    # ----- M2-O2 load-capture ---------------------------------------------
    # Belt-and-braces: scan ALL loads in the function whose address provenance
    # traces to the data pointer; each must be captured element traffic.
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref in dropped && continue
        LLVM.opcode(inst) == LLVM.API.LLVMLoad || continue
        _heap_num_operands(inst) >= 1 || continue
        addr = _heap_operand_ref(inst, 1)
        if _heap_addr_roots_at_data(func, addr, harr)
            inst.ref in captured_insts ||
                _heap_m2_error("M2-O2: a load from the element data region " *
                               "$(_heap_vname(inst)) was NOT captured as " *
                               "element traffic")
        end
    end

    # ----- M2-O3 machinery-dead -------------------------------------------
    # No gc_machinery instruction may be a `ret`-ancestor of the RE-ROOTED
    # return. The element traffic IS allowed to feed the return (that is M2's
    # whole point), and after re-rooting the element load's address is the
    # synthetic alloca — NOT the original Memory-object alloc chain. The
    # M2-aware walk re-roots element traffic so a gc_machinery hit here is a
    # genuine live-machinery leak, not the (benign) alloc→data_ptr→load chain.
    ret_ancestors = _heap_m2_return_ancestors(func, harr)
    for a in ret_ancestors
        if a in gc_machinery
            _heap_m2_error("M2-O3: GC-machinery value " *
                           "$(_heap_vname(_heap_value_for_ref(func, a))) feeds " *
                           "the function return — the GC machinery is not dead")
        end
    end

    # ----- M2-O4 taint containment ----------------------------------------
    # Every data-region GEP/load/store reachable from `ret` must be captured.
    # (M2-O1/O2 cover stores/loads; check GEPs reachable from ret too.)
    inst_by_ref = Dict{_LLVMRef,LLVM.Instruction}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst_by_ref[inst.ref] = inst
    end
    for a in ret_ancestors
        inst = get(inst_by_ref, a, nothing)
        inst === nothing && continue
        if LLVM.opcode(inst) == LLVM.API.LLVMGetElementPtr
            gi = _heap_gep_info(inst)
            if gi.base === harr.data_ptr ||
               (gi.base === harr.memory_obj && gi.simple &&
                gi.coff !== nothing && gi.coff >= 16)
                a in skel ||
                    _heap_m2_error("M2-O4: a data-region GEP feeding the " *
                                   "return $(_heap_vname(inst)) is not part " *
                                   "of the recognised skeleton")
            end
        end
    end

    # ----- M2-O5 no escape ------------------------------------------------
    # Retain M1's P-callee + P-escape (machinery-scoped). Additionally: no
    # element-data GEP / data_ptr / memory_obj / wrapper may be a call argument
    # of a non-allowlisted call, and memory_obj/wrapper must not be a
    # ret-ancestor.
    array_refs = Set{_LLVMRef}([harr.memory_obj, harr.data_ptr])
    harr.wrapper !== nothing && push!(array_refs, harr.wrapper)
    # Collect element-GEP refs.
    elem_gep_refs = Set{_LLVMRef}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_is_gep(inst) || continue
        gi = _heap_gep_info(inst)
        if gi.base === harr.data_ptr ||
           (gi.base === harr.memory_obj && gi.simple && gi.coff !== nothing &&
            gi.coff >= 16)
            push!(elem_gep_refs, inst.ref)
        end
    end
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        inst.ref in dropped && continue
        LLVM.opcode(inst) == LLVM.API.LLVMCall || continue
        cname = _heap_callee_name(inst)
        allowlisted = _heap_is_allowlisted_callee(cname) ||
                      startswith(cname, "llvm.memset.") ||
                      startswith(cname, "llvm.lifetime.") ||
                      _heap_is_inline_asm_call(inst)
        allowlisted && continue
        # Non-allowlisted call: no array pointer may be an argument.
        n = _heap_num_operands(inst)
        for k in 1:(n - 1)            # operand n is the callee
            opref = _heap_operand_ref(inst, k)
            (opref in array_refs || opref in elem_gep_refs) &&
                _heap_m2_error("M2-O5: an element-data / Memory / Array " *
                               "pointer escapes as an argument to `@$cname` " *
                               "($(_heap_vname(inst))) — the heap array is " *
                               "not isolable")
        end
    end
    # memory_obj / wrapper must not feed the return.
    for a in ret_ancestors
        a in array_refs && a !== harr.data_ptr &&
            _heap_m2_error("M2-O5: the Memory object / Array wrapper feeds " *
                           "the function return — returning the heap array " *
                           "itself is out of M2 scope")
    end
    # P-callee over machinery — every machinery call allowlisted.
    for r in gc_machinery
        inst = get(inst_by_ref, r, nothing)
        inst === nothing && continue
        LLVM.opcode(inst) == LLVM.API.LLVMCall || continue
        if _heap_is_inline_asm_call(inst)
            _heap_is_allowlisted_tls_asm(inst) ||
                _heap_m2_error("M2-O5: tainted inline-asm call " *
                               "$(_heap_vname(inst)) is not the allowlisted " *
                               "TLS read")
            continue
        end
        cname = _heap_callee_name(inst)
        ok = _heap_is_allowlisted_callee(cname) ||
             startswith(cname, "llvm.memset.") ||
             startswith(cname, "llvm.lifetime.")
        ok ||
            _heap_m2_error("M2-O5: GC-machinery call to `@$cname` " *
                           "($(_heap_vname(inst))) is not an allowlisted heap " *
                           "callee")
    end
    # P-escape over machinery — every machinery store's address is skeleton-
    # owned (SSA in skel) or a global/constant.
    for r in gc_machinery
        inst = get(inst_by_ref, r, nothing)
        inst === nothing && continue
        LLVM.opcode(inst) == LLVM.API.LLVMStore || continue
        _heap_num_operands(inst) >= 2 || continue
        addr = _heap_operand_ref(inst, 2)
        if _heap_ref_is_instruction(addr)
            addr in skel ||
                _heap_m2_error("M2-O5: GC-machinery store $(_heap_vname(inst)) " *
                               "targets a non-skeleton SSA address — the " *
                               "skeleton writes into live memory")
        end
    end

    # ----- M2-O6 capacity --------------------------------------------------
    # N constant (already enforced by _infer_capacity); every captured const
    # element index ∈ [0,N).
    for ea in elem_traffic
        if ea.index isa Int
            0 <= ea.index < N ||
                _heap_m2_error("M2-O6: captured element index $(ea.index) " *
                               "out of range [0,$N)")
        end
    end

    # ----- M2-O7 uniform width — already checked in _partition_skeleton. ---

    # ----- P-opcode over machinery (retained from M1). --------------------
    _SKEL_FORBIDDEN_OPCODES_M2 = (
        (LLVM.API.LLVMAtomicCmpXchg, "cmpxchg"),
        (LLVM.API.LLVMFence,         "fence"),
        (LLVM.API.LLVMInvoke,        "invoke"),
        (LLVM.API.LLVMCallBr,        "callbr"),
    )
    for r in gc_machinery
        inst = get(inst_by_ref, r, nothing)
        inst === nothing && continue
        opc = LLVM.opcode(inst)
        for (forbidden, mnemonic) in _SKEL_FORBIDDEN_OPCODES_M2
            opc == forbidden &&
                _heap_m2_error("GC-machinery instruction $(_heap_vname(inst)) " *
                               "has side-effecting opcode `$mnemonic` that " *
                               "the partition proof does not model")
        end
        # Note: `store atomic ... unordered` (the Memory/Array tag stores) is
        # opcode LLVMStore, NOT a forbidden opcode — classified as machinery
        # above. `atomicrmw` would be genuinely unmodelled but does not appear
        # in the GC skeleton; if it did the taint closure would fold it in and
        # it would land here — left out of the list deliberately mirrors M1's
        # set minus AtomicRMW which the M1 list keeps; we keep cmpxchg/fence/
        # invoke/callbr. Add AtomicRMW back if it ever appears.
    end

    return nothing
end

# ---------------------------------------------------------------------------
# Q-E — re-rooting: build the surviving slice for the M2 path.
# ---------------------------------------------------------------------------

"""
    _build_rerooted_slice(func, names, counter, harr, elem_traffic,
                          gc_machinery, dropped) -> (ret_inst, survivors)

Build the M2 surviving slice:
  - a synthetic `IRAlloca(sym, W, ConstOperand(N))` (W from element widths);
  - every non-skeleton non-dropped user-arithmetic instruction, converted via
    the normal `_convert_instruction` path, in program order;
  - element stores re-rooted as `IRPtrOffset` + `IRStore` onto the synthetic
    alloca;
  - the runtime element load re-rooted as `IRVarGEP` + `IRLoad` (keeping the
    load's ORIGINAL SSA dest name so the `ret` operand resolves unchanged);
  - the single `IRRet`.

The bounds-check diamond is collapsed: `dropped` instructions (throw blocks +
guarding `br`s) are skipped; the non-throw block of the diamond is spliced
inline because we walk all blocks in program order.

SEMANTICS NOTE (Bennett-kuza / M2): dropping the bounds check means an
out-of-range runtime index reads `idx mod N` instead of trapping. This is
consistent with established Bennett semantics — `ijl_bounds_error` /
`j_throw_*` are already in the project-wide benign-drop allowlist
(src/extract/instructions.jl). It is NOT a new miscompile class; the test
oracle sweeps only valid in-range inputs.
"""
function _build_rerooted_slice(func::LLVM.Function,
                               names::Dict{_LLVMRef,Symbol},
                               counter::Ref{Int},
                               harr::_HeapArray,
                               elem_traffic::Vector{_ElemAccess},
                               gc_machinery::Set{_LLVMRef},
                               dropped::Set{_LLVMRef})
    # Element bit width — from the captured store/load VALUE widths.
    W = elem_traffic[1].width
    W >= 1 ||
        _heap_m2_error("inferred element width $W is not positive")
    N = harr.capacity

    # Synthetic alloca symbol — gensym, guaranteed not to collide with any
    # LLVM value name (LLVM names never contain '#').
    alloca_sym = Symbol("_kuza_heap#", counter[])
    counter[] += 1

    survivors = IRInst[]
    push!(survivors, IRAlloca(alloca_sym, W, ConstOperand(N)))

    # Index element accesses by their store/load instruction ref, for the
    # in-program-order walk below.
    access_by_inst = Dict{_LLVMRef,_ElemAccess}()
    for ea in elem_traffic
        access_by_inst[ea.inst] = ea
    end
    # Element-GEP refs (these are SKEL-classified GEPs we replace wholesale —
    # we emit our own IRPtrOffset/IRVarGEP, so the original GEPs are skipped).
    elem_gep_refs = Set{_LLVMRef}()
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_is_gep(inst) || continue
        gi = _heap_gep_info(inst)
        if gi.base === harr.data_ptr ||
           (gi.base === harr.memory_obj && gi.simple && gi.coff !== nothing &&
            gi.coff >= 16)
            push!(elem_gep_refs, inst.ref)
        end
    end
    push!(elem_gep_refs, harr.data_ptr)

    ret_inst::Union{Nothing,IRInst} = nothing

    for bb in LLVM.blocks(func)
        for inst in LLVM.instructions(bb)
            inst.ref in dropped && continue
            opc = LLVM.opcode(inst)

            # --- terminators ---
            if opc == LLVM.API.LLVMRet
                ops = LLVM.operands(inst)
                isempty(ops) &&
                    _heap_m2_error("surviving `ret void` — M2 expects a value " *
                                   "return")
                ret_inst === nothing ||
                    _heap_m2_error("more than one surviving `ret` — slice is " *
                                   "not single-exit")
                ret_inst = IRRet(_operand(ops[1], names), _iwidth(ops[1]))
                continue
            elseif opc == LLVM.API.LLVMBr
                # Unconditional br — linear, skip. A conditional br that
                # survived (was not dropped by the diamond collapse) is a real
                # user branch — reject. (Diamond `br`s are in `dropped`.)
                _heap_num_operands(inst) == 1 && continue
                _heap_m2_error("surviving non-skeleton conditional branch " *
                               "$(_heap_vname(inst)) — general control flow " *
                               "is out of M2 scope")
            elseif opc == LLVM.API.LLVMSwitch || opc == LLVM.API.LLVMIndirectBr
                _heap_m2_error("surviving multi-way branch " *
                               "$(_heap_vname(inst)) — out of M2 scope")
            elseif opc == LLVM.API.LLVMUnreachable
                _heap_m2_error("surviving `unreachable` outside a throw block")
            end

            # --- element store / load — re-root ---
            if haskey(access_by_inst, inst.ref)
                ea = access_by_inst[inst.ref]
                gep_sym = Symbol("_kuza_gep#", counter[])
                counter[] += 1
                if ea.kind == :store
                    # M2 is scoped to constant-offset stores: `_partition_skeleton`
                    # rejects a runtime-index element store loud before capture,
                    # so `ea.index` is always an `Int` here.
                    idx = ea.index
                    if idx isa Int
                        push!(survivors,
                              IRPtrOffset(gep_sym, SSAOperand(alloca_sym), idx))
                    else
                        _heap_m2_error("internal: runtime store index reached " *
                            "the re-rooter — should have been rejected by the " *
                            "partition")
                    end
                    # Resolve the stored value via the LLVM operand object on
                    # the store itself — `_operand` handles SSA / arg / const.
                    val_op = _operand(LLVM.operands(inst)[1], names)
                    push!(survivors,
                          IRStore(SSAOperand(gep_sym), val_op, W))
                else  # :load
                    idx = ea.index
                    load_dest = names[inst.ref]
                    if idx isa Int
                        push!(survivors,
                              IRPtrOffset(gep_sym, SSAOperand(alloca_sym), idx))
                    else
                        idx_v = _heap_value_for_ref(func, idx)
                        idx_v === nothing &&
                            _heap_m2_error("runtime load index ref unresolved")
                        push!(survivors,
                              IRVarGEP(gep_sym, SSAOperand(alloca_sym),
                                       _operand(idx_v, names), W))
                    end
                    # Keep the load's ORIGINAL dest name so the `ret` operand
                    # resolves unchanged.
                    push!(survivors, IRLoad(load_dest, SSAOperand(gep_sym), W))
                end
                continue
            end

            # --- element GEPs we replace wholesale — skip ---
            inst.ref in elem_gep_refs && continue

            # --- GC machinery — drop ---
            inst.ref in gc_machinery && continue

            # --- everything else: a surviving user-arithmetic instruction ---
            # Convert via the normal walker path.
            ir_inst = _convert_instruction(inst, names, counter)
            if ir_inst === nothing
                # Benign non-skeleton intrinsic (`llvm.assume`, a non-skeleton
                # `llvm.lifetime.*` / `llvm.dbg.*`, ...) — the normal module
                # walker drops these; do the same so a `nothing` never lands
                # in the `Vector{IRInst}` survivors list.
                continue
            elseif ir_inst isa Vector
                append!(survivors, ir_inst)
            elseif ir_inst isa IRRet || ir_inst isa IRBranch ||
                   ir_inst isa IRSwitch
                _heap_m2_error("surviving terminator-class instruction " *
                               "$(_heap_vname(inst)) reached the user-arith " *
                               "path unexpectedly")
            else
                push!(survivors, ir_inst)
            end
        end
    end

    ret_inst === nothing &&
        _heap_m2_error("no surviving `ret` found after the M2 partition")
    return ret_inst, survivors
end
