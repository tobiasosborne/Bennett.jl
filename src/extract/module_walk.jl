# ---- module walking ----

# Find the entry function. When `entry_function === nothing`, pick the first
# `julia_*` function with a body (the legacy heuristic used by
# `extract_parsed_ir(f, T)`). When a name is supplied, do an exact match on
# `LLVM.name(f)`; fail loud if missing / declaration-only / ambiguous.
function _find_entry_function(mod::LLVM.Module,
                              entry_function::Union{Nothing, AbstractString})
    if entry_function === nothing
        for f in LLVM.functions(mod)
            if startswith(LLVM.name(f), "julia_") && !isempty(LLVM.blocks(f))
                return f
            end
        end
        throw(ArgumentError("ir_extract.jl: no julia_* function found in LLVM module (the " *
              "extractor expects code_llvm(...; dump_module=true) output with " *
              "at least one non-declaration `julia_` or `j_` function)"))
    end

    matches = LLVM.Function[]
    for f in LLVM.functions(mod)
        LLVM.name(f) == String(entry_function) && push!(matches, f)
    end
    if isempty(matches)
        names = [LLVM.name(f) for f in LLVM.functions(mod)]
        candidate_blurb = isempty(names) ? "(module has no functions)" :
            "candidates: " * join(names, ", ")
        throw(ArgumentError("ir_extract.jl: entry function `$entry_function` not found in " *
              "module. $candidate_blurb"))
    end
    if length(matches) > 1
        throw(ArgumentError("ir_extract.jl: entry function `$entry_function` matches " *
              "$(length(matches)) functions in the module (expected 1)"))
    end
    f = matches[1]
    isempty(LLVM.blocks(f)) &&
        throw(ArgumentError("ir_extract.jl: entry function `$entry_function` is a " *
              "declaration (has no body); provide a module that defines it"))
    return f
end

# Dispatch wrapper: preserves the historical `_module_to_parsed_ir(mod)`
# behaviour when called with no selector, and routes to the core walker on
# a selected function.
function _module_to_parsed_ir(mod::LLVM.Module;
                              entry_function::Union{Nothing, AbstractString}=nothing,
                              mem::Symbol=:auto)
    func = _find_entry_function(mod, entry_function)
    return _module_to_parsed_ir_on_func(mod, func; mem=mem)
end

# Core walker: `mod` provides module-scope globals / constants; `func` is the
# entry point (already picked by `_find_entry_function`).
#
# `mem` (Bennett-gps7 / M1): when `:heap`, the GC/heap-skeleton recogniser
# runs after the naming pass. Under any other value (`:auto` default) the
# recogniser does NOT run — the walk is byte-identical to pre-M1 behaviour.
function _module_to_parsed_ir_on_func(mod::LLVM.Module, func::LLVM.Function;
                                      mem::Symbol=:auto)
    counter = Ref(0)

    # T1c.2: extract compile-time-constant global arrays so lower_var_gep! can
    # dispatch read-only lookups through QROM instead of a MUX-tree.
    # Bennett-land: returns both the globals dict and the
    # synth_ptr_provenance set (entries for ptr-field structs that were
    # materialised with synthetic 64-bit addresses; consumed by the
    # downstream load-escape guard).
    globals, synth_ptr_provenance = _extract_const_globals(mod)

    # Bennett-land: per-function tracking of alloca refs that received
    # synthetic-address bytes via memcpy. Populated by
    # `_handle_memcpy_global_src` (initial tag) and `_handle_memcpy_arm`
    # (carry-through tag). Consulted by `_handle_load`'s escape guard.
    synth_ptr_allocas = Set{_LLVMRef}()

    # Bennett-dv1z: detect sret calling convention. When present, the LLVM
    # return type is `void`; the aggregate shape comes from the sret attribute.
    sret_info = _detect_sret(func)

    # Return type derivation — sret overrides the void return with the
    # aggregate described by the sret attribute.
    if sret_info !== nothing
        ret_width       = sret_info.n_elems * sret_info.elem_width
        ret_elem_widths = [sret_info.elem_width for _ in 1:sret_info.n_elems]
    else
        ft = LLVM.function_type(func)
        rt = LLVM.return_type(ft)
        ret_width = _type_width(rt)
        ret_elem_widths = if rt isa LLVM.ArrayType
            [LLVM.width(LLVM.eltype(rt)) for _ in 1:LLVM.length(rt)]
        else
            [ret_width]
        end
    end

    # Build name table: LLVMValueRef → Symbol  (two-pass: name everything first)
    names = Dict{_LLVMRef, Symbol}()
    # Bennett-cc0.7: per-lane side table for vector SSA values. Populated
    # during pass 2 in source order by `_convert_vector_instruction`.
    lanes = Dict{_LLVMRef, Vector{IROperand}}()

    # Name parameters
    args = Tuple{Symbol,Int}[]
    # Track pointer params: map ptr SSA name → (base_sym, byte_size) for GEP/load resolution
    ptr_params = Dict{Symbol, Tuple{Symbol, Int}}()
    for (i, p) in enumerate(LLVM.parameters(func))
        nm = LLVM.name(p)
        sym = isempty(nm) ? _auto_name(counter) : Symbol(nm)
        names[p.ref] = sym
        # sret parameter is an output buffer, not a function input. Name it so
        # sret-targeted stores resolve through `names`, but skip adding it to
        # `args` — otherwise the wire allocator would reserve input wires for
        # a value the caller never supplies.
        if sret_info !== nothing && i == sret_info.param_index
            continue
        end
        ptype = LLVM.value_type(p)
        if ptype isa LLVM.IntegerType
            push!(args, (sym, LLVM.width(ptype)))
        elseif ptype isa LLVM.FloatingPointType
            # Float params are just N-bit values (double=64, float=32)
            push!(args, (sym, _type_width(ptype)))
        elseif ptype isa LLVM.PointerType
            # Pointer arg (e.g., NTuple passed by reference)
            # Try to determine size from dereferenceable attribute or skip (pgcstack)
            deref = _get_deref_bytes(func, p)
            if deref > 0
                # Treat as flat wire array: deref bytes × 8 bits
                w = deref * 8
                push!(args, (sym, w))
                ptr_params[sym] = (sym, deref)
            end
            # pgcstack and other non-dereferenceable ptrs are silently skipped
        end
    end

    # Name all instructions (first pass)
    for bb in LLVM.blocks(func)
        for inst in LLVM.instructions(bb)
            nm = LLVM.name(inst)
            names[inst.ref] = isempty(nm) ? _auto_name(counter) : Symbol(nm)
        end
    end

    # sret pre-walk: classify stores/GEPs that target the sret buffer and
    # record the per-slot stored values. Must run after the naming pass so
    # _operand() can resolve SSA references.
    sret_writes = sret_info === nothing ? nothing :
                  _collect_sret_writes(func, sret_info, names)

    # Bennett-gps7 / M1: GC/heap-skeleton recogniser. Runs ONLY when
    # `mem === :heap`. When it recognises + proves a dead heap skeleton it
    # short-circuits the whole walk: the surviving non-skeleton slice is
    # straight-line by M1 condition 4, so the function collapses to a
    # single-block ParsedIR. Under `mem=:auto` (default) `_detect_gc_preamble!`
    # returns an inert result immediately and this branch is skipped — the
    # default extraction path is byte-identical to pre-M1.
    heap_skel = _detect_gc_preamble!(func, names, mem)
    if heap_skel.recognised
        block = IRBasicBlock(:top, heap_skel.survivors, heap_skel.ret_inst)
        return ParsedIR(ret_width, args, [block], ret_elem_widths, globals,
                        nothing, synth_ptr_provenance)
    end

    # Convert blocks (second pass)
    blocks = IRBasicBlock[]
    for bb in LLVM.blocks(func)
        label = Symbol(LLVM.name(bb))
        insts = IRInst[]
        terminator = nothing

        for inst in LLVM.instructions(bb)
            # sret hook: suppress instructions already accounted for in the
            # pre-walk (sret-targeting stores and their constant-offset GEPs).
            if sret_writes !== nothing && inst.ref in sret_writes.suppressed
                continue
            end
            # sret hook: at `ret void`, emit the synthetic IRInsertValue chain
            # plus IRRet equivalent to the n=2 by-value aggregate-return path.
            if sret_writes !== nothing &&
               LLVM.opcode(inst) == LLVM.API.LLVMRet &&
               isempty(LLVM.operands(inst))
                # Bennett-0c8o: before synthesising, confirm every pending
                # vector sret store was resolved during pass 2.
                _assert_no_pending_vec_stores!(sret_writes)
                chain, ret_inst = _synthesize_sret_chain(
                    sret_info, sret_writes.slot_values, counter)
                append!(insts, chain)
                terminator = ret_inst
                continue
            end

            # Bennett-cc0.3: skip instructions whose dispatch crashes on
            # Julia runtime artifacts — LLVMGlobalAlias refs (ptr globals
            # like @"jl_global#NNN.jit"), or helper calls that assume
            # integer widths on pointer-typed aggregate members. Skipped
            # instructions leave their SSA dest un-bound; downstream
            # consumers that actually read the dest raise an ErrorException
            # at `_operand` lookup time, which still satisfies the T5 corpus
            # `@test_throws`. User arithmetic (which doesn't touch runtime
            # ptrs) extracts normally.
            #
            # Bennett-g27k / U18: gate each benign-skip on BOTH an exception
            # type AND the expected message pattern. The old code matched
            # substrings against `sprint(showerror, e)` alone, so ANY error
            # whose message happened to contain "PointerType", "Unknown
            # value kind", or "LLVMGlobalAlias" got silently swallowed —
            # including unrelated bugs in our own extractor or in user
            # functions. Narrowed matches:
            #   - ErrorException with "Unknown value kind" → LLVM.jl
            #     `value.jl:20` fallback (e.g. LLVMGlobalAlias)
            #   - ErrorException with "LLVMGlobalAlias" → same family
            #   - MethodError with "PointerType" → LLVM.jl dispatch gap on
            #     pointer-typed aggregate members
            # Bennett's own `_ir_error` uses ErrorException too, but its
            # message always begins with `"ir_extract.jl: "`; gating on that
            # prefix is how we distinguish legitimate fail-loud errors from
            # LLVM.jl's "unknown kind" pass-through.
            ir_inst = try
                _convert_instruction(inst, names, counter, lanes;
                                     globals=globals,
                                     synth_ptr_provenance=synth_ptr_provenance,
                                     synth_ptr_allocas=synth_ptr_allocas)
            catch e
                e isa InterruptException && rethrow()
                msg = sprint(showerror, e)
                bennett_authored = startswith(msg, "ErrorException(") ?
                    false : occursin("ir_extract.jl:", msg) ||
                            occursin("Bennett-", msg)
                benign = !bennett_authored && (
                    (e isa ErrorException && (
                        occursin("Unknown value kind", msg) ||
                        occursin("LLVMGlobalAlias", msg))) ||
                    (e isa MethodError && occursin("PointerType", msg))
                )
                benign ? nothing : rethrow()
            end
            ir_inst === nothing && continue
            # Bennett-0c8o: after each successful conversion, if `inst` was
            # the producer of a pending sret vector store's stored value,
            # harvest its lanes now.
            if sret_writes !== nothing
                _resolve_pending_vec_for_val!(sret_writes, inst.ref, lanes)
            end
            if ir_inst isa Vector
                for sub in ir_inst
                    push!(insts, sub)
                end
            elseif ir_inst isa IRRet || ir_inst isa IRBranch || ir_inst isa IRSwitch
                terminator = ir_inst
            else
                push!(insts, ir_inst)
            end
        end

        terminator === nothing && throw(AssertionError(
            "ir_extract.jl: block in @$(LLVM.name(func)):%$label has no terminator"))
        push!(blocks, IRBasicBlock(label, insts, terminator))
    end

    # Post-pass: expand switch terminators into cascaded icmp + branch blocks
    blocks = _expand_switches(blocks)

    return ParsedIR(ret_width, args, blocks, ret_elem_widths, globals,
                    nothing, synth_ptr_provenance)
end

"""
Bennett-land: synthetic-address constants for ptr-typed ConstantStruct
fields.

`_LAND_SYNTH_ADDR_BASE` (`0x1000_0000_0000_0000`) is the high-nibble
prefix that makes synthetic addresses visually distinguishable from real
allocator addresses (`0x0000_7FFF_FFFF_FFFF` and below on canonical
x86_64) and from small integer constants. The next 60 bits hold the
per-module monotonic counter, giving ~2^60 unique slots — vastly more
than any practical module exercises (t5 corpus uses ~28 ptr-containing
structs).

Per the orchestrator-synthesised spec for Bennett-land: B's monotonic
counter is preferred over A's hash-based scheme because uniqueness is
guaranteed by construction (no birthday collisions) and the assignment
is deterministic across runs of the same module (since
`LLVM.globals(mod)` iterates in module-insertion order).
"""
const _LAND_SYNTH_ADDR_BASE = UInt64(0x1000_0000_0000_0000)

"""
Assign a synthetic 64-bit little-endian address for a named global
pointee. Idempotent: a second lookup of the same `gname` returns the
same address (so two ptr-fields pointing at the same global pack to
identical bytes — semantically correct).

Returns the assigned `UInt64`. Mutates `addr_assigned` and bumps
`addr_counter`.

Lives OUTSIDE `_extract_const_globals` per Bennett-8kno's static
substring inspection (test_8kno's catch-block fingerprint must remain
byte-identical).
"""
function _assign_synthetic_addr!(addr_assigned::Dict{Symbol, UInt64},
                                 addr_counter::Base.RefValue{UInt64},
                                 gname::Symbol)::UInt64
    haskey(addr_assigned, gname) && return addr_assigned[gname]
    addr = _LAND_SYNTH_ADDR_BASE | addr_counter[]
    addr_counter[] += UInt64(1)
    addr_assigned[gname] = addr
    return addr
end

"""
Bennett-zxhg helper (Bennett-land extension). Flatten a `ConstantStruct`
initializer into a flat little-endian `Vector{UInt8}` honoring ABI
offset/padding via `LLVM.offsetof(dl, struct_ty, i)` and total size via
`LLVM.abi_size(dl, struct_ty)`.

Returns `(nothing, provenance)` (hard-reject; provenance unchanged) if
ANY field has a type or operand-shape Bennett.jl can't materialise:
  - FloatType / VectorType / opaque / IntegerType wider than 64
  - PointerType with non-zero addrspace (Bennett-land-addrspace follow-up)
  - PointerType with size != 8 bytes (Bennett-land-ptrsize32 follow-up)
  - PointerType with operand identity `(:addr, K)` (inttoptr-of-const) —
    K could be a real allocator address (Bennett-land-inttoptr follow-up)
  - PointerType with operand identity `nothing` (undef / unresolvable)
  - nested ConstantStruct that itself returns `nothing`
  - field operand of an unexpected kind (e.g. `undef`, ConstantExpr that's
    not a ConstantInt/ConstantDataArray/ConstantStruct/ConstantAggregateZero)

Otherwise returns `(bytes, new_provenance_entries)` where
`new_provenance_entries::Vector{Tuple{Int,Int}}` is the list of
`(field_byte_offset, field_byte_width)` pairs (only populated for ptr
fields with `(:named, ref)` or `(:null, 0)` identity). The CALLER
(`_extract_const_globals`) folds these into the module-scope
`synth_ptr_provenance` set under the global's name.

`addr_assigned` and `addr_counter` thread the per-module synthetic-
address state. Recursion preserves them so nested struct ptrs reuse the
same address pool.

Bennett-land scope:
  - Bennett-zxhg hard-rejected ALL ptr fields by returning `nothing`
    at the final `else` arm. land splits the ptr arm out: `(:named, _)`
    and `(:null, 0)` materialise; `(:addr, _)` and `nothing` still
    reject. The downstream G5 message still mentions
    `Bennett-zxhg-ptrfield` for these residual reject cases but adds
    `Bennett-land-ptrload` as the new escape-guard breadcrumb.

Depth-limited at 8 to match `_global_root_and_offset` and prevent
pathological recursion on hostile input.
"""
function _flatten_struct_to_bytes(init::LLVM.ConstantStruct,
                                  struct_ty::LLVM.StructType,
                                  dl::LLVM.DataLayout,
                                  addr_assigned::Dict{Symbol, UInt64},
                                  addr_counter::Base.RefValue{UInt64},
                                  depth::Int=0)
    depth >= 8 && return (nothing, Tuple{Int,Int}[])
    # Endianness assertion (cheap insurance for big-endian deployment).
    LLVM.byteorder(dl) == LLVM.API.LLVMLittleEndian ||
        return (nothing, Tuple{Int,Int}[])

    total_bytes = Int(LLVM.abi_size(dl, struct_ty))
    bytes = zeros(UInt8, total_bytes)
    # Per-call ptr-provenance entries, returned to caller for folding
    # into the module-scope synth_ptr_provenance set.
    ptr_prov = Tuple{Int,Int}[]

    field_types = collect(LLVM.elements(struct_ty))
    field_vals  = LLVM.operands(init)
    nfields = length(field_types)
    length(field_vals) == nfields || return (nothing, Tuple{Int,Int}[])

    for i in 0:(nfields - 1)
        field_off = Int(LLVM.offsetof(dl, struct_ty, i))
        field_ty  = field_types[i + 1]
        field_val = field_vals[i + 1]

        if field_ty isa LLVM.IntegerType
            w = LLVM.width(field_ty)
            (w in (8, 16, 32, 64)) || return (nothing, Tuple{Int,Int}[])
            # ConstantAggregateZero on a sub-int field is just zero —
            # bytes already zero, nothing to do.
            if field_val isa LLVM.ConstantAggregateZero
                # no-op
            elseif field_val isa LLVM.ConstantInt
                raw = UInt64(LLVM.API.LLVMConstIntGetZExtValue(field_val.ref))
                nb = div(w, 8)
                for k in 0:(nb - 1)
                    bytes[field_off + k + 1] = UInt8((raw >> (8 * k)) & 0xff)
                end
            else
                return (nothing, Tuple{Int,Int}[])
            end

        elseif field_ty isa LLVM.ArrayType
            elem_ty = LLVM.eltype(field_ty)
            elem_ty isa LLVM.IntegerType || return (nothing, Tuple{Int,Int}[])
            ew = LLVM.width(elem_ty)
            (ew in (8, 16, 32, 64)) || return (nothing, Tuple{Int,Int}[])
            arrlen = Int(LLVM.API.LLVMGetArrayLength(field_ty.ref))
            nb_per = div(ew, 8)

            if field_val isa LLVM.ConstantAggregateZero
                # bytes already zero
            elseif field_val isa LLVM.ConstantDataArray ||
                   field_val isa LLVM.ConstantArray
                for k in 0:(arrlen - 1)
                    elt_ref = LLVM.API.LLVMGetElementAsConstant(field_val.ref, k)
                    elt = LLVM.Value(elt_ref)
                    raw = elt isa LLVM.ConstantInt ?
                        UInt64(LLVM.API.LLVMConstIntGetZExtValue(elt.ref)) :
                        UInt64(0)
                    base = field_off + k * nb_per
                    for b in 0:(nb_per - 1)
                        bytes[base + b + 1] = UInt8((raw >> (8 * b)) & 0xff)
                    end
                end
            else
                return (nothing, Tuple{Int,Int}[])
            end

        elseif field_ty isa LLVM.StructType
            if field_val isa LLVM.ConstantAggregateZero
                # bytes already zero
            elseif field_val isa LLVM.ConstantStruct
                sub_bytes, sub_prov = _flatten_struct_to_bytes(
                    field_val, field_ty, dl, addr_assigned, addr_counter, depth + 1)
                sub_bytes === nothing && return (nothing, Tuple{Int,Int}[])
                length(sub_bytes) == Int(LLVM.abi_size(dl, field_ty)) ||
                    return (nothing, Tuple{Int,Int}[])
                for (j, b) in enumerate(sub_bytes)
                    bytes[field_off + j] = b
                end
                # Lift nested ptr-prov entries up to outer-struct offsets.
                for (sub_off, sub_w) in sub_prov
                    push!(ptr_prov, (field_off + sub_off, sub_w))
                end
            else
                return (nothing, Tuple{Int,Int}[])
            end

        elseif field_ty isa LLVM.PointerType
            # Bennett-land: materialise narrow ptr-field operand shapes.
            # Reject early on addrspace != 0 or pointer-size != 8.
            LLVM.addrspace(field_ty) == 0 ||
                return (nothing, Tuple{Int,Int}[])
            ptr_size = Int(LLVM.pointersize(dl, 0))
            ptr_size == 8 || return (nothing, Tuple{Int,Int}[])

            if LLVM.API.LLVMGetValueKind(field_val.ref) ==
               LLVM.API.LLVMConstantPointerNullValueKind
                # 8 zero bytes — already zeroed. No counter bump (null is
                # not allocated a synthetic address). Still record
                # provenance: the load-escape guard MUST trip on a load
                # from a struct-with-ptr-field even if THAT particular
                # ptr happens to be null (the escape check is alloca-
                # level, not field-level, in this MVP).
                # NOTE: LLVM.jl 9 has no `ConstantPointerNull` wrapper —
                # dispatch via raw value-kind enum.
                push!(ptr_prov, (field_off, ptr_size))
            else
                # Reuse `_ptr_identity` (Bennett-cc0) for canonical
                # identity. Returns:
                #   (:named, ref)  → assign synthetic address
                #   (:null,  0)    → 8 zero bytes (rare; covered above)
                #   (:addr,  K)    → REJECT (allocator-dependent;
                #                    Bennett-land-inttoptr follow-up)
                #   nothing        → REJECT (undef / unresolvable)
                ident = _ptr_identity(field_val.ref)
                ident === nothing && return (nothing, Tuple{Int,Int}[])
                kind, payload = ident
                if kind === :null
                    # 8 zero bytes; already zeroed.
                    push!(ptr_prov, (field_off, ptr_size))
                elseif kind === :named
                    target_name = Symbol(LLVM.name(LLVM.Value(payload)))
                    addr = _assign_synthetic_addr!(addr_assigned, addr_counter,
                                                   target_name)
                    for k in 0:(ptr_size - 1)
                        bytes[field_off + k + 1] = UInt8((addr >> (8 * k)) & 0xff)
                    end
                    push!(ptr_prov, (field_off, ptr_size))
                else
                    # :addr (inttoptr-of-const) — REJECT in MVP.
                    return (nothing, Tuple{Int,Int}[])
                end
            end

        else
            # FloatType / VectorType / opaque / TokenType / etc.
            # — hard-reject via the Bennett-zxhg-ptrfield breadcrumb at the
            # downstream G5 call site.
            return (nothing, Tuple{Int,Int}[])
        end
    end

    return (bytes, ptr_prov)
end

"""
Extract constant-initialized integer-array globals from `mod`.

Returns a dict keyed by global name (Symbol) mapping to `(data, elem_width)` where
`data` is the array contents zero-extended into UInt64 (one entry per element) and
`elem_width` is the per-element bit width from the LLVM type.

Dispatch on initializer kind (Bennett-zxhg extension):
  - `ConstantDataArray` on `ArrayType<IntegerType, 8/16/32/64>` — original path
    (per-element packing at the natural `elem_width`).
  - `ConstantStruct` on `StructType` — new arm (Bennett-zxhg): flatten to
    byte stream via `_flatten_struct_to_bytes`; stored as
    `(UInt64.(bytes), 8)`. ABI padding honored via `LLVM.offsetof`.
  - `ConstantAggregateZero` on `StructType` or `ArrayType` — new arm
    (Bennett-zxhg companion): all-zero bytes of `LLVM.abi_size(dl, ty)`,
    stored as `(zeros(UInt64, total_bytes), 8)`.

Skips non-constant globals, opaque initializers, and anything that doesn't
fit one of the three dispatch arms. Hard-rejects struct globals with any
non-integer-shaped field (ptr/float/vector/etc.) via
`_flatten_struct_to_bytes` returning `nothing` → silently skipped here,
with the precise breadcrumb fired downstream at
`_handle_memcpy_global_src` G5 (instructions.jl).
"""
function _extract_const_globals(mod::LLVM.Module)
    out = Dict{Symbol, Tuple{Vector{UInt64}, Int}}()
    # Bennett-land: per-module synthetic-address state for ptr-typed
    # ConstantStruct fields. `addr_assigned` maps pointee global name to
    # its assigned 64-bit synthetic address (idempotent — two ptrs to
    # the same global pack to identical bytes). `addr_counter` is the
    # monotonic source for new addresses. `synth_ptr_provenance` records
    # which (struct_global, field_offset, field_width) tuples were
    # materialised this way, for the downstream load-escape guard.
    addr_assigned = Dict{Symbol, UInt64}()
    addr_counter  = Ref(UInt64(0))
    synth_ptr_provenance = Set{Tuple{Symbol, Int, Int}}()
    dl = LLVM.datalayout(mod)
    for g in LLVM.globals(mod)
        # Julia emits various globals (type references, aliases, dispatch tables)
        # whose initializers we can't meaningfully materialize. Guard with a
        # try/catch because LLVM.initializer errors for unknown value kinds
        # (e.g. GlobalAlias).
        LLVM.isconstant(g) || continue
        init = try
            LLVM.initializer(g)
        catch e
            # Bennett-uinn / U93: re-raise InterruptException (Ctrl-C).
            e isa InterruptException && rethrow()
            # Bennett-8kno / U95: only swallow LLVM.jl's own
            # "Unknown value kind" / "LLVMGlobalAlias" errors —
            # exactly what the comment above predicts. OutOfMemoryError,
            # StackOverflowError, MethodError, and other unexpected
            # exceptions propagate out so a real bug isn't masked.
            msg = sprint(showerror, e)
            benign = e isa ErrorException && (
                occursin("Unknown value kind", msg) ||
                occursin("LLVMGlobalAlias", msg))
            benign ? nothing : rethrow()
        end
        init === nothing && continue

        if init isa LLVM.ConstantDataArray
            ty = LLVM.value_type(init)
            ty isa LLVM.ArrayType || continue
            elem_ty = LLVM.eltype(ty)
            elem_ty isa LLVM.IntegerType || continue
            elem_width = LLVM.width(elem_ty)
            1 <= elem_width <= 64 || continue
            n = Int(LLVM.API.LLVMGetArrayLength(ty.ref))
            data = Vector{UInt64}(undef, n)
            for i in 0:(n-1)
                elt_ref = LLVM.API.LLVMGetElementAsConstant(init.ref, i)
                elt = LLVM.Value(elt_ref)
                data[i+1] = elt isa LLVM.ConstantInt ?
                    UInt64(LLVM.API.LLVMConstIntGetZExtValue(elt.ref)) : UInt64(0)
            end
            out[Symbol(LLVM.name(g))] = (data, elem_width)

        elseif init isa LLVM.ConstantStruct
            ty = LLVM.value_type(init)
            ty isa LLVM.StructType || continue
            bytes, ptr_prov = _flatten_struct_to_bytes(
                init, ty, dl, addr_assigned, addr_counter, 0)
            bytes === nothing && continue
            gname = Symbol(LLVM.name(g))
            out[gname] = (UInt64.(bytes), 8)
            # Bennett-land: fold this struct's ptr-field entries into the
            # module-scope provenance set.
            for (foff, fw) in ptr_prov
                push!(synth_ptr_provenance, (gname, foff, fw))
            end

        elseif init isa LLVM.ConstantAggregateZero
            ty = LLVM.value_type(init)
            if ty isa LLVM.StructType
                total_bytes = Int(LLVM.abi_size(dl, ty))
                out[Symbol(LLVM.name(g))] = (zeros(UInt64, total_bytes), 8)
            elseif ty isa LLVM.ArrayType
                # An all-zero array also lands here in LLVM 18 (not as a
                # ConstantDataArray). Preserve the natural element-width
                # dict shape for integer-typed arrays.
                elem_ty = LLVM.eltype(ty)
                if elem_ty isa LLVM.IntegerType
                    ew = LLVM.width(elem_ty)
                    if 1 <= ew <= 64
                        n = Int(LLVM.API.LLVMGetArrayLength(ty.ref))
                        out[Symbol(LLVM.name(g))] = (zeros(UInt64, n), ew)
                    end
                end
                # non-integer-element arrays silently skipped
            end
            # other zero-init types (vector, etc.) silently skipped

        else
            continue
        end
    end
    return out, synth_ptr_provenance
end

"""
Expand IRSwitch terminators into cascaded comparison blocks.

switch val, default [c1 → L1, c2 → L2, ...] becomes:

    orig   : icmp eq val, c1 → br (L1, _sw_orig_2)
    _sw_2  : icmp eq val, c2 → br (L2, _sw_orig_3)
    ...
    _sw_N  : icmp eq val, cN → br (LN, default)

Phi nodes in successor blocks are rewritten: each pre-expansion incoming
`(val, orig_switch_label)` is replaced by one incoming per unique
post-expansion predecessor block of the phi's host (a target shared by
several cases is reached from the case-1 slot AND the syn block of every
other case pointing at it; the default may share a syn block with the
last case).

Bennett-u21m / U11 fixes:
  (1) Phi patching runs as a single global sweep AFTER all switches have
      been expanded — the old per-switch sweep missed phis in successor
      blocks that hadn't been appended to `result` yet.
  (2) `pred_map` is keyed by `(orig_switch_label, target_label)` and
      stores the full set of synthetic predecessors, so duplicate targets
      no longer collapse into a single wrong incoming.
"""
function _expand_switches(blocks::Vector{IRBasicBlock})
    # Bennett-t3j0 / U83: defensive collision guard. The synthetic block
    # labels emitted below (`_sw_<orig>_<i>` and `_sw_cmp_<orig>_<i>`) and
    # the `:__unreachable__` sentinel produced by `LLVMUnreachable` are
    # reserved namespaces. If an input block already uses one — which
    # would happen on accidental re-run of `_expand_switches` on its own
    # output, or on a future caller passing crafted blocks — silent
    # shadowing would corrupt phi rewiring and topological order.
    for b in blocks
        s = String(b.label)
        startswith(s, "_sw_") &&
            throw(AssertionError("_expand_switches: input block label :$(b.label) collides " *
                  "with the reserved synthetic-block prefix `_sw_*`. " *
                  "Likely a re-run on already-expanded blocks (Bennett-t3j0 / U83)."))
        b.label === :__unreachable__ &&
            throw(AssertionError("_expand_switches: input block named :__unreachable__ " *
                  "collides with the reserved unreachable-target sentinel " *
                  "(Bennett-t3j0 / U83)."))
    end

    result = IRBasicBlock[]
    orig_switches = Set{Symbol}()
    # (orig_switch_label, target_label) → ordered list of unique synthetic
    # predecessors of target_label inherited from this switch.
    pred_map = Dict{Tuple{Symbol, Symbol}, Vector{Symbol}}()

    @inline function _add_pred!(orig_label::Symbol, tgt::Symbol, src::Symbol)
        lst = get!(pred_map, (orig_label, tgt), Symbol[])
        src in lst || push!(lst, src)
        return nothing
    end

    # ── Phase A: expand every switch into cmp blocks; populate pred_map ──
    for block in blocks
        if !(block.terminator isa IRSwitch)
            push!(result, block)
            continue
        end

        sw = block.terminator
        orig_label = block.label
        n_cases = length(sw.cases)

        if n_cases == 0
            # Degenerate: just unconditional branch to default.
            push!(result, IRBasicBlock(orig_label, block.instructions,
                                       IRBranch(nothing, sw.default_label, nothing)))
            push!(orig_switches, orig_label)
            _add_pred!(orig_label, sw.default_label, orig_label)
            continue
        end

        push!(orig_switches, orig_label)
        syn_labels = [Symbol("_sw_$(orig_label)_$i") for i in 1:n_cases]

        # First block — the original block keeps its label so existing
        # predecessors still see it, with the first icmp appended.
        cmp_dest_1 = Symbol("_sw_cmp_$(orig_label)_1")
        first_cmp = IRICmp(cmp_dest_1, :eq, sw.cond, sw.cases[1][1], sw.cond_width)
        first_false = n_cases >= 2 ? syn_labels[2] : sw.default_label
        first_br = IRBranch(ssa(cmp_dest_1), sw.cases[1][2], first_false)
        push!(result, IRBasicBlock(orig_label,
                                   vcat(block.instructions, [first_cmp]),
                                   first_br))
        _add_pred!(orig_label, sw.cases[1][2], orig_label)

        # Middle comparison blocks (cases 2..N-1).
        for i in 2:(n_cases - 1)
            cmp_dest = Symbol("_sw_cmp_$(orig_label)_$i")
            cmp = IRICmp(cmp_dest, :eq, sw.cond, sw.cases[i][1], sw.cond_width)
            br = IRBranch(ssa(cmp_dest), sw.cases[i][2], syn_labels[i + 1])
            push!(result, IRBasicBlock(syn_labels[i], [cmp], br))
            _add_pred!(orig_label, sw.cases[i][2], syn_labels[i])
        end

        # Last comparison block: its false-branch goes to the switch default.
        if n_cases >= 2
            cmp_dest_n = Symbol("_sw_cmp_$(orig_label)_$n_cases")
            cmp_n = IRICmp(cmp_dest_n, :eq, sw.cond, sw.cases[n_cases][1], sw.cond_width)
            br_n = IRBranch(ssa(cmp_dest_n), sw.cases[n_cases][2], sw.default_label)
            push!(result, IRBasicBlock(syn_labels[n_cases], [cmp_n], br_n))
            _add_pred!(orig_label, sw.cases[n_cases][2], syn_labels[n_cases])
            _add_pred!(orig_label, sw.default_label,     syn_labels[n_cases])
        else
            # n_cases == 1: default is reached from orig_label's false-branch.
            _add_pred!(orig_label, sw.default_label, orig_label)
        end
    end

    # ── Phase B: global phi patching ───────────────────────────────────
    # For every phi, an incoming `(val, from)` where `from` is an expanded
    # switch label expands to one incoming per unique synthetic predecessor
    # of the phi's host block inherited from that switch. Multiple cases
    # sharing a target produce multiple incomings; a target reached by
    # both default and a case through the same syn block gets deduped by
    # `_add_pred!` above.
    if !isempty(orig_switches)
        for j in eachindex(result)
            blk = result[j]
            new_insts = IRInst[]
            changed = false
            for inst in blk.instructions
                if inst isa IRPhi
                    new_incoming = Tuple{IROperand, Symbol}[]
                    for (val, from_block) in inst.incoming
                        if from_block in orig_switches
                            preds = get(pred_map, (from_block, blk.label), Symbol[])
                            if isempty(preds)
                                # Defensive: phi cited a switch block that
                                # doesn't actually branch to this block.
                                # Leave the incoming alone rather than
                                # silently dropping it; a downstream phi
                                # resolver will raise if this is malformed.
                                push!(new_incoming, (val, from_block))
                            else
                                for p in preds
                                    push!(new_incoming, (val, p))
                                end
                                changed = true
                            end
                        else
                            push!(new_incoming, (val, from_block))
                        end
                    end
                    push!(new_insts, IRPhi(inst.dest, inst.width, new_incoming))
                else
                    push!(new_insts, inst)
                end
            end
            if changed
                result[j] = IRBasicBlock(blk.label, new_insts, blk.terminator)
            end
        end
    end

    return result
end

