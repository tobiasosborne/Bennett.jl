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
                              mem::Symbol)
    mem === :heap || return _HeapSkeleton()

    # ---- Count gc_small_alloc calls. Zero ⇒ inert; >1 ⇒ reject. ----
    allocs = LLVM.Instruction[]
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_callee_name(inst) == "ijl_gc_small_alloc" && push!(allocs, inst)
    end
    isempty(allocs) && return _HeapSkeleton()
    length(allocs) == 1 ||
        _heap_error("$(length(allocs)) `@ijl_gc_small_alloc` calls found; M1 " *
                    "supports exactly one heap allocation per function. " *
                    "Multi-allocation heap code is out of M1 scope")

    # A recognised skeleton is present — from here every exit is either a
    # proven success or a loud reject.
    _assert_memory_layout()

    # Reject heap allocation inside a loop body (back-edge). M1 targets
    # straight-line + a fully-skeleton diamond only.
    _heap_assert_no_backedge(func, allocs[1])

    skel = _recognise_skeleton(func, allocs[1])
    _prove_skeleton_dead(func, skel, names)

    # Build the surviving single-block return.
    ret_inst, survivors = _build_surviving_slice(func, skel, names)

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
function _recognise_skeleton(func::LLVM.Function, alloc::LLVM.Instruction)
    skel = Set{_LLVMRef}()

    # ---- Seeds ----
    # (1) every alloca in the entry block — gcframe [7 x ptr], growend
    #     scratch [9 x i64], sret_box [2 x i64]. M1 heap functions place all
    #     skeleton allocas at the top; a non-skeleton alloca would be caught
    #     downstream by the proof (P-noload / straight-line check).
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        LLVM.opcode(inst) == LLVM.API.LLVMAlloca && push!(skel, inst.ref)
    end

    # (2) the gc alloc itself.
    push!(skel, alloc.ref)

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
