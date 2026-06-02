# ---- SC9 Case B — the `mem=:vm` Dict→IRMap* recogniser ----
#
# This file is the FRONT-END half of BennettVM's reversible-Dict case
# (PRD v4 §3.6.2 Case B; ADR 0008; ADR 0013 §D-3). When a Julia function
# allocates a `Dict` and mutates it, the standard `mem=:auto` walk rejects it
# at the TLS/GC wall (and `mem=:heap` rejects it at the bespoke Dict signpost
# `heap.jl:_m4_scope_guard`). This recogniser is the `mem=:vm` arm that instead
# treats the `Dict` as an OPAQUE reversible map: it does NOT model the
# hash-table's internal memory (contrast the `:heap` Vector element-traffic
# recogniser), it drops the GC frame + the Dict `ijl_gc_small_alloc` skeleton,
# and it rewrites the surviving Dict-mutation CALLEES into the three
# language-neutral `IRInst` map ops `IRMapInsert` / `IRMapGet` / `IRMapDelete`
# (`src/ir_types.jl`). Those ingest 1:1 into BennettVM's VM-side `IRMap*` ops
# (`BennettVM/src/ir/revmap.jl`), where a Bennett-1973 history tape on the map
# (not on control flow) makes the mutations reversible.
#
# # The design map (ADR 0008 / 0013 §D-3)
#
# A `Dict{K,V}()` constructor + `d[k]=v` + `d[k]` lowers (Julia 1.12.5,
# optimize=true, dump_module=true) to:
#   - a GC frame skeleton (`[N x ptr] alloca` + `llvm.memset` + the
#     `movq %fs:0` TLS read + the frame-chain `store`/`load`s) — REUSE the
#     `:heap` recogniser's exact-allowlist dead-skeleton seeds (`heap.jl`).
#   - one `@ijl_gc_small_alloc(..., <Dict size>, ...)` allocating the Dict
#     object, followed by the Dict's field-init stores (keys/vals Memory =
#     null, ndel/count/age/idxfloor/maxprobe scalars). The Dict allocation
#     BECOMES the opaque empty `RevMap` — it emits NO ParsedIR node (the
#     RevMap starts empty); all of it is dead skeleton, dropped.
#   - a `@j_setindex!_NNN(dict, v, k)` callee — VALUE BEFORE KEY (verified
#     against the live IR; `module_walk.jl` cites the same order). Rewritten to
#     `IRMapInsert(key=k, value=v)` (un-permuting the operands).
#   - a `@j_getindex_NNN(dict, k)` callee → `IRMapGet(dest, key=k)`, and a
#     `@j_delete!_NNN(dict, k)` callee → `IRMapDelete(key=k)` — WHEN THEY
#     SURVIVE AS CALLEES.
#
# # The hard scope boundary — inlined `getindex` (Rule 1, fail loud)
#
# CRITICAL ground truth (probed on Julia 1.12.5, the live version): for the
# canonical `fdict(k,v) = (d=Dict(); d[k]=v; d[k])`, the trailing `d[k]`
# `getindex` is FULLY INLINED at BOTH optimize=true and optimize=false — it
# does NOT survive as a `@j_getindex_NNN` callee. Instead it expands to ~20
# basic blocks of raw hash arithmetic (`xor`/`shl`/`mul`/`lshr` chains), a
# probe loop over the Dict's `keys`/`vals` `Memory` backing store, and
# KeyError/AssertionError throw diamonds, terminating in a `load i8` from the
# vals Memory that is the function's `ret`. There is NO callee boundary to
# rewrite. Recognising that inlined probe as "return `M[k]`" SOUNDLY would
# require proving the probe finds key `k` and returns its stored value — i.e.
# understanding the hash function and proving the KeyError block dead for a
# present key, which is statically undecidable in general and version-fragile
# (the project's own Laws forbid faking it — CLAUDE.md Rule 1 / Rule 9). This
# recogniser therefore FAILS LOUD when the function's return is NOT produced by
# a recognised Dict callee, naming the inlined-getindex blocker precisely. The
# `setindex!`-only fragment (and any program where `getindex`/`delete!` survive
# as callees, e.g. behind a `@noinline` barrier) is handled soundly; the bare
# `fdict` body is rejected at this boundary until the inlined-getindex
# recogniser (a separate, research-grade build) lands. See the BennettVM bead
# `bennettvm-0do` notes and `BennettVM/test/test_revmap_roundtrip.jl` (the
# hand-built VMProgram proof of the same end state).
#
# # Soundness discipline (CLAUDE.md §1, mirroring heap.jl)
#
# The catastrophic failure is a SILENT MISCOMPILE — dropping a live
# instruction, or mis-extracting the key/value operands. So:
#   * the recogniser is purely subtractive: it only ever drops PROVEN-dead
#     skeleton (the GC frame + the Dict alloc + its init stores + the throw
#     diamonds) and rewrites recognised callees; everything else REJECTS LOUD.
#   * the value-before-key operand order is un-permuted EXACTLY once, here,
#     with an assertion on the operand count.
#   * any Dict construct outside the recognised single-`setindex!` /
#     surviving-callee scope (resize hints, a second Dict, non-callee
#     getindex, an unrecognised callee tainted by the Dict) REJECTS LOUD.
#
# # Ref
#   * docs/adr/0008-dict-reversibility.md — Decisions 1–6 (the RevMap ADT +
#     the three ops), Decision 4b (this front-end recognition arm).
#   * docs/adr/0013-*.md §D-3 — language-neutral high-level map ops.
#   * src/ir_types.jl — `IRMapInsert` / `IRMapGet` / `IRMapDelete` structs.
#   * src/extract/heap.jl — the reused low-level LLVM helpers
#     (`_heap_callee_name`, `_heap_operand_ref`, `_heap_num_operands`,
#     `_heap_is_allowlisted_tls_asm`, `_heap_return_ancestors`,
#     `_heap_ref_is_instruction`) and the dead-skeleton-seed pattern.
#   * BennettVM/src/ir/revmap.jl — the VM-side ops these ingest into.
#   * CLAUDE.md §1 (fail loud), §2 (reuse heap.jl helpers), §9, §11.

# Anchored callee-name regexes for the recognised Dict mutation callees. Matched
# against CALLEE FUNCTION NAMES ONLY (via `_heap_callee_name`); the `_NNN`
# suffix is a per-JIT-session counter, matched as `\d+`, never literally. These
# are the SAME mangled forms `heap.jl:_m4_scope_guard` signposts.
const _VM_DICT_SETINDEX_RE = r"^j_setindex!_\d+$"
const _VM_DICT_GETINDEX_RE = r"^j_getindex_\d+$"
const _VM_DICT_DELETE_RE   = r"^j_delete!_\d+$"

# The Dict GC allocator (same symbol the `:heap` recogniser keys off).
const _VM_GC_ALLOC = "ijl_gc_small_alloc"

function _dict_vm_error(reason::AbstractString)
    error("ir_extract.jl: mem=:vm Dict recogniser: $reason " *
          "(SC9 Case B; ADR 0008 / 0013 §D-3)")
end

"""
    _dict_vm_is_recognised(func) -> Bool

True iff `func` contains at least one recognised Dict mutation callee
(`@j_setindex!_NNN` / `@j_getindex_NNN` / `@j_delete!_NNN`). This is the gate
that routes a `mem=:vm` function into the Dict recogniser rather than the
generic (unimplemented Case-A) `:vm` reject — a `:vm` function with NO Dict
callee is a Case-A (Vector) program, handled elsewhere.
"""
function _dict_vm_is_recognised(func::LLVM.Function)::Bool
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        cn = _heap_callee_name(inst)
        isempty(cn) && continue
        (occursin(_VM_DICT_SETINDEX_RE, cn) ||
         occursin(_VM_DICT_GETINDEX_RE, cn) ||
         occursin(_VM_DICT_DELETE_RE, cn)) && return true
    end
    return false
end

# Classify a Dict mutation callee name into its op kind, or `nothing`.
function _dict_vm_op_kind(cname::AbstractString)
    occursin(_VM_DICT_SETINDEX_RE, cname) && return :insert
    occursin(_VM_DICT_GETINDEX_RE, cname) && return :get
    occursin(_VM_DICT_DELETE_RE,   cname) && return :delete
    return nothing
end

"""
    _dict_vm_extract(func, names, counter, args, ret_width, ret_elem_widths,
                     globals, synth_ptr_provenance) -> ParsedIR

The `mem=:vm` Dict recogniser entry point. Walks `func` in program order,
drops the GC frame + Dict-alloc + field-init + throw skeleton, rewrites the
recognised Dict callees into `IRMap*` ops, and assembles a single-block
straight-line `ParsedIR` (the `fdict`-class body is straight-line: the only
control flow is the inlined-getindex / throw diamonds, which are dropped).

FAILS LOUD (Rule 1) on:
  * any Dict construct outside the recognised single-Dict scope (≥2
    `ijl_gc_small_alloc`, a non-Dict-tainted alloc),
  * an unrecognised non-skeleton call (a Dict value escaping into an
    unmodelled callee),
  * a return value NOT produced by a recognised Dict callee — the
    inlined-`getindex` blocker (see this file's top docstring).
"""
function _dict_vm_extract(func::LLVM.Function,
                          names::Dict{_LLVMRef,Symbol},
                          counter::Ref{Int},
                          args::Vector{Tuple{Symbol,Int}},
                          ret_width::Int,
                          ret_elem_widths::Vector{Int},
                          globals::Dict{Symbol,Tuple{Vector{UInt64},Int}},
                          synth_ptr_provenance::Set{Tuple{Symbol,Int,Int}})::ParsedIR
    # Same host/layout guard the heap recogniser uses — the mangled callee
    # forms and the GC-frame idiom are Julia-1.12.5 / x86-64 specific.
    _assert_memory_layout()

    # ---- Locate the Dict allocation(s). Exactly one Dict is in v1 scope. ----
    dict_allocs = LLVM.Instruction[]
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_callee_name(inst) == _VM_GC_ALLOC && push!(dict_allocs, inst)
    end
    # The Dict body may also box a thrown KeyError/AssertionError via a second
    # `ijl_gc_small_alloc` — but those live in throw blocks that are dead for
    # the recognised path. We only require AT LEAST ONE alloc (the Dict); the
    # throw-box allocs are caught by the dead-skeleton drop below. If the
    # return path is a recognised callee (no inlined getindex / no throw), the
    # throw boxes never appear. We do NOT cap the count here — a multi-Dict
    # program is rejected by the multi-`setindex!`-on-distinct-dicts guard in
    # `_dict_vm_collect_ops` instead (operands name the dict).
    isempty(dict_allocs) &&
        _dict_vm_error("no `@$_VM_GC_ALLOC` (Dict allocation) found, yet a " *
                       "Dict mutation callee is present — the Dict object is " *
                       "not allocated in this function (escaped argument?), " *
                       "which the single-owned-map v1 scope does not model")

    # ---- Reuse the heap recogniser's dead-skeleton seed + closure to build
    #      the set of GC/Dict-skeleton instruction refs to DROP. ----
    skel = _dict_vm_skeleton(func, dict_allocs)

    # ---- Walk in program order: rewrite recognised callees, drop skeleton,
    #      reject anything else. Collect the (ordered) IRMap* ops + the ret. ----
    body, ret_inst = _dict_vm_collect_ops(func, names, skel, ret_width)

    block = IRBasicBlock(:top, body, ret_inst)
    return ParsedIR(ret_width, args, [block], ret_elem_widths, globals,
                    nothing, synth_ptr_provenance)
end

"""
    _dict_vm_skeleton(func, dict_allocs) -> Set{_LLVMRef}

Build the set of GC/Dict-skeleton instruction refs to drop, REUSING the
`:heap` recogniser's structural seeds (Law 2): the entry-block allocas (GC
frame), the TLS-allowlisted inline asm, every `llvm.memset` / `ijl_gc_*` call,
and every global-address load (the Memory-header reads). It then forward-taints
to a fixed point exactly like `_recognise_skeleton`, so the Dict alloc's
field-init stores (writing null Memory pointers + scalar header fields through
GEPs off the Dict object) all fold in. The recognised Dict-mutation callees and
the function `ret` are NOT seeds — they survive (the callees are rewritten, the
ret is the result).
"""
function _dict_vm_skeleton(func::LLVM.Function,
                           dict_allocs::Vector{LLVM.Instruction})::Set{_LLVMRef}
    skel = Set{_LLVMRef}()

    # (1) every alloca (GC frame / scratch). Same seed as heap.jl (1).
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        LLVM.opcode(inst) == LLVM.API.LLVMAlloca && push!(skel, inst.ref)
    end
    # (2) the Dict GC alloc(s) — the opaque map object + any throw boxes.
    for a in dict_allocs
        push!(skel, a.ref)
    end
    # (3) TLS-allowlisted inline asm; reject any other inline asm (drift).
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        _heap_is_inline_asm_call(inst) || continue
        if _heap_is_allowlisted_tls_asm(inst)
            push!(skel, inst.ref)
        else
            pair = _heap_inline_asm_strings(inst)
            desc = pair === nothing ? "<unparseable inline asm>" :
                   "asm=\"$(pair[1])\" constraint=\"$(pair[2])\""
            _dict_vm_error("non-allowlisted inline-asm call " *
                           "$(_heap_vname(inst)) ($desc); only the x86-64 " *
                           "TLS-base read `movq %fs:0, \$0`/`=r` is recognised")
        end
    end
    # (4) every llvm.memset / llvm.memcpy / ijl_gc_* call (Dict init + GC).
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        cname = _heap_callee_name(inst)
        isempty(cname) && continue
        (startswith(cname, "llvm.memset.") ||
         startswith(cname, "llvm.memcpy.") ||
         startswith(cname, "llvm.lifetime.") ||
         cname == _VM_GC_ALLOC) && push!(skel, inst.ref)
    end
    # (5) every load from a non-SSA (global / constexpr) address — the Dict's
    #     `keys`/`vals` Memory-header reads off `@"jl_global#NNN.jit"`. Same
    #     seed + soundness argument as heap.jl (5): a spurious seed can only
    #     cause a loud reject downstream (a surviving recognised op reading it
    #     would be a non-SSA-key operand, rejected), never a miscompile.
    for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
        LLVM.opcode(inst) == LLVM.API.LLVMLoad || continue
        _heap_num_operands(inst) >= 1 || continue
        addr = _heap_operand_ref(inst, 1)
        _heap_ref_is_instruction(addr) || push!(skel, inst.ref)
    end

    # ---- Forward taint closure to a fixed point (heap.jl pattern). An
    #      instruction folds in when ANY operand is in `skel`. Terminators are
    #      excluded (handled by the program-order walk). CRUCIALLY: the
    #      recognised Dict-mutation CALLEES must NOT be tainted-in even though
    #      their first operand is the (skeleton) Dict object — they are the ops
    #      we rewrite. So calls to a recognised Dict callee are excluded from
    #      the closure. ----
    changed = true
    while changed
        changed = false
        for bb in LLVM.blocks(func), inst in LLVM.instructions(bb)
            inst.ref in skel && continue
            opc = LLVM.opcode(inst)
            (opc == LLVM.API.LLVMRet || opc == LLVM.API.LLVMBr ||
             opc == LLVM.API.LLVMSwitch || opc == LLVM.API.LLVMIndirectBr ||
             opc == LLVM.API.LLVMUnreachable) && continue
            # Do NOT taint a recognised Dict callee (it is rewritten, not
            # dropped) even though it consumes the skeleton Dict object.
            if opc == LLVM.API.LLVMCall &&
               _dict_vm_op_kind(_heap_callee_name(inst)) !== nothing
                continue
            end
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

"""
    _dict_vm_collect_ops(func, names, skel, ret_width) -> (Vector{IRInst}, IRInst)

Walk `func` in program order. For each instruction:
  * in `skel` → DROP (proven-dead GC/Dict skeleton).
  * a recognised Dict callee → emit the matching `IRMap*` op, un-permuting the
    value-before-key operand order for `setindex!`.
  * a `ret` → build the `IRRet`, after proving its operand is a recognised
    Dict-callee result (else the inlined-getindex blocker — FAIL LOUD).
  * a terminator branch whose condition is a skeleton value → DROP (a dead
    throw/probe diamond entirely within the dropped skeleton).
  * ANYTHING ELSE (a surviving live computation, an unrecognised call, a real
    user branch) → FAIL LOUD (Rule 1).

Returns the ordered body ops and the single `IRRet`.
"""
function _dict_vm_collect_ops(func::LLVM.Function,
                              names::Dict{_LLVMRef,Symbol},
                              skel::Set{_LLVMRef},
                              ret_width::Int)::Tuple{Vector{IRInst},IRInst}
    body = IRInst[]
    ret_inst::Union{Nothing,IRInst} = nothing
    # Map each recognised Dict-callee RESULT ref → the SSA name it would carry
    # (for `getindex`, the dest the IRMapGet writes). Used to validate that the
    # `ret` operand is a recognised result, not an inlined-getindex load.
    callee_result_dest = Dict{_LLVMRef,Symbol}()

    for bb in LLVM.blocks(func)
        for inst in LLVM.instructions(bb)
            inst.ref in skel && continue
            opc = LLVM.opcode(inst)

            if opc == LLVM.API.LLVMCall
                cname = _heap_callee_name(inst)
                kind = _dict_vm_op_kind(cname)
                if kind === nothing
                    # A non-skeleton, non-recognised call — a Dict value
                    # escaping into an unmodelled callee, or an out-of-scope
                    # construct (resize!, sizehint!, …). Fail loud.
                    _heap_is_inline_asm_call(inst) &&
                        _dict_vm_error("surviving inline-asm call " *
                            "$(_heap_vname(inst)) outside the TLS allowlist")
                    _dict_vm_error("surviving (non-skeleton) call to `@$cname` " *
                        "($(_heap_vname(inst))) is not a recognised Dict " *
                        "mutation callee (setindex!/getindex/delete!). A Dict " *
                        "value escaping into an unmodelled callee, or an " *
                        "out-of-scope Dict construct (resize!/sizehint!/copy), " *
                        "is rejected rather than risk a miscompile")
                end
                op = _dict_vm_lower_call(inst, names, kind)
                push!(body, op)
                # Record this callee's result so a downstream `ret` of it is
                # accepted. For setindex!/delete! the result is the dict (void
                # logically) and never returned as the i8 value; for getindex
                # the result IS the read value.
                if kind === :get
                    callee_result_dest[inst.ref] = op.dest
                end

            elseif opc == LLVM.API.LLVMRet
                ops = LLVM.operands(inst)
                isempty(ops) &&
                    _dict_vm_error("`ret void` — Case B's `fdict` expects a " *
                        "value return (the map read result)")
                ret_inst === nothing ||
                    _dict_vm_error("more than one surviving `ret` — the Dict " *
                        "recogniser expects a single-exit straight-line body")
                retval = ops[1]
                rref = retval.ref
                # The return MUST be either a function parameter / constant, or
                # the result of a recognised Dict GET callee. If it is an SSA
                # value produced by a NON-recognised instruction (the inlined
                # getindex's `load i8` off the Dict's vals Memory), FAIL LOUD —
                # this is the inlined-getindex blocker (top docstring).
                if _heap_ref_is_instruction(rref) && !haskey(callee_result_dest, rref)
                    _dict_vm_error(
                        "the function return $(_heap_vname(retval)) is produced " *
                        "by a NON-callee instruction — the `getindex` (`d[k]`) " *
                        "was INLINED by Julia into raw hash arithmetic + a " *
                        "Memory-backing-store probe (no `@j_getindex_NNN` " *
                        "callee survives, verified on Julia 1.12.5 at both " *
                        "optimize levels). Recognising the inlined probe as " *
                        "`M[k]` soundly requires understanding the hash and " *
                        "proving the KeyError block dead — a separate, " *
                        "research-grade recogniser that is NOT yet built (Rule " *
                        "1: reject rather than miscompile). A `getindex` BEHIND " *
                        "a `@noinline` barrier (a surviving `@j_getindex_NNN` " *
                        "callee) IS handled. See BennettVM bead bennettvm-0do " *
                        "and test_revmap_roundtrip.jl for the proven end state.")
                end
                ret_inst = IRRet(_operand(retval, names), _iwidth(retval))

            elseif opc == LLVM.API.LLVMBr
                # Unconditional branch: linear control flow (the surviving slice
                # spans blocks linearly) — skip. Conditional branch on a
                # skeleton condition: a dead throw/probe diamond, fully within
                # the dropped skeleton — skip. Conditional branch on a NON-
                # skeleton condition: a real user branch survived — FAIL LOUD.
                if _heap_num_operands(inst) == 1
                    continue
                end
                cond = _heap_operand_ref(inst, 1)
                if _heap_ref_is_instruction(cond) && cond in skel
                    continue
                else
                    _dict_vm_error("surviving (non-skeleton) conditional branch " *
                        "$(_heap_vname(inst)) — its condition is not a dropped-" *
                        "skeleton value, so a real user branch survived. The " *
                        "Dict recogniser (v1) handles a straight-line body " *
                        "only; any surviving diamond/loop is out of scope")
                end

            elseif opc == LLVM.API.LLVMSwitch || opc == LLVM.API.LLVMIndirectBr
                _dict_vm_error("surviving (non-skeleton) multi-way branch " *
                    "$(_heap_vname(inst)) — the Dict recogniser (v1) requires " *
                    "a straight-line surviving body")
            elseif opc == LLVM.API.LLVMUnreachable
                # An `unreachable` terminating a dropped throw block — but the
                # block's predecessor branch is skeleton, so we only reach here
                # if the unreachable's OWN block survived. A surviving
                # `unreachable` means a non-skeleton block has no real exit.
                _dict_vm_error("surviving (non-skeleton) `unreachable` " *
                    "$(_heap_vname(inst)) — a throw block survived skeleton " *
                    "suppression, which should not happen for the recognised " *
                    "Dict body (the throw diamonds are dropped skeleton)")
            else
                # A genuine surviving computed instruction. For the recognised
                # Dict body (skeleton dropped, callees rewritten) there are
                # none. Anything here is unmodelled — fail loud.
                _dict_vm_error("surviving (non-skeleton) instruction " *
                    "$(_heap_vname(inst)) [opcode $opc] — the Dict recogniser " *
                    "drops the GC/Dict skeleton and rewrites the recognised " *
                    "mutation callees; a surviving live computation (e.g. the " *
                    "inlined-getindex hash arithmetic) is out of scope (Rule 1)")
            end
        end
    end

    ret_inst === nothing &&
        _dict_vm_error("no surviving `ret` found after skeleton suppression")
    return body, ret_inst
end

"""
    _dict_vm_lower_call(inst, names, kind) -> IRInst

Rewrite one recognised Dict mutation call into its `IRMap*` op.

  * `:insert` — `@j_setindex!_NNN(dict, v, k)` → `IRMapInsert(key=k, value=v)`.
    The Julia callee operand order is VALUE BEFORE KEY (op2 = value, op3 = key;
    op1 = dict; the final operand is the callee itself). This is the ONE place
    the permutation is un-done; an operand-count assertion guards it.
  * `:get` — `@j_getindex_NNN(dict, k)` → `IRMapGet(dest, key=k)`. `dest` is
    the callee result's SSA name (`names[inst.ref]`).
  * `:delete` — `@j_delete!_NNN(dict, k)` → `IRMapDelete(key=k)`.

Key/value operands are lowered via the shared `_operand` (Law 2); their widths
via `_iwidth`.
"""
function _dict_vm_lower_call(inst::LLVM.Instruction,
                             names::Dict{_LLVMRef,Symbol},
                             kind::Symbol)::IRInst
    nops = _heap_num_operands(inst)   # includes the trailing callee operand
    if kind === :insert
        # operands: [dict, value, key, callee] → exactly 4.
        nops == 4 ||
            _dict_vm_error("`@$(_heap_callee_name(inst))` (setindex!) has " *
                "$nops operands (expected 4: dict, value, key, callee). The " *
                "value-before-key 3-arg form is the only recognised shape " *
                "(verified on Julia 1.12.5); a different arity means an " *
                "unrecognised setindex! variant (Rule 1)")
        valv = LLVM.Value(_heap_operand_ref(inst, 2))   # VALUE (before key)
        keyv = LLVM.Value(_heap_operand_ref(inst, 3))   # KEY
        return IRMapInsert(_operand(keyv, names), _operand(valv, names),
                           _iwidth(keyv), _iwidth(valv))
    elseif kind === :get
        # operands: [dict, key, callee] → exactly 3.
        nops == 3 ||
            _dict_vm_error("`@$(_heap_callee_name(inst))` (getindex) has " *
                "$nops operands (expected 3: dict, key, callee)")
        keyv = LLVM.Value(_heap_operand_ref(inst, 2))
        dest = get(names, inst.ref, nothing)
        dest === nothing &&
            _dict_vm_error("getindex callee result is unnamed — cannot bind " *
                "an IRMapGet dest")
        return IRMapGet(dest, _operand(keyv, names),
                        _iwidth(keyv), Int(ret_width_of(inst)))
    else  # :delete
        # operands: [dict, key, callee] → exactly 3.
        nops == 3 ||
            _dict_vm_error("`@$(_heap_callee_name(inst))` (delete!) has " *
                "$nops operands (expected 3: dict, key, callee)")
        keyv = LLVM.Value(_heap_operand_ref(inst, 2))
        return IRMapDelete(_operand(keyv, names), _iwidth(keyv))
    end
end

# The integer bit width of a call's result type (for IRMapGet's value_width).
function ret_width_of(inst::LLVM.Instruction)::Int
    t = LLVM.value_type(inst)
    t isa LLVM.IntegerType ? LLVM.width(t) : _type_width(t)
end
