using InteractiveUtils: code_llvm
using LLVM

"""
    extract_ir(f, arg_types; optimize=true) -> String

Get the LLVM IR string for a Julia function (kept for debugging/printing).
"""
function extract_ir(f, arg_types::Type{<:Tuple}; optimize::Bool=true)
    return sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize))
end

"""
    extract_parsed_ir(f, arg_types; optimize=true) -> ParsedIR

Extract LLVM IR via LLVM.jl's typed API and convert to ParsedIR.
Uses dump_module=true to include function declarations needed for call inlining.
"""
function extract_parsed_ir(f, arg_types::Type{<:Tuple}; optimize::Bool=true)
    ir_string = sprint(io -> code_llvm(io, f, arg_types; debuginfo=:none, optimize, dump_module=true))

    local result::ParsedIR
    LLVM.Context() do _ctx
        mod = parse(LLVM.Module, ir_string)
        result = _module_to_parsed_ir(mod)
        dispose(mod)
    end
    return result
end

# ---- known callee registry for gate-level inlining ----

const _known_callees = Dict{String, Function}()

"""Register a Julia function for gate-level inlining when encountered as an LLVM call."""
function register_callee!(f::Function)
    # Get the LLVM name Julia would give this function (j_name_NNN pattern)
    # We match by substring, so just store the Julia function name
    _known_callees[string(nameof(f))] = f
end

function _lookup_callee(llvm_name::String)
    for (jname, f) in _known_callees
        if occursin(jname, lowercase(llvm_name))
            return f
        end
    end
    return nothing
end

# ---- value identity via C pointer ----

const _LLVMRef = LLVM.API.LLVMValueRef

# Auto-name counter
const _name_counter = Ref(0)
function _reset_names!()
    _name_counter[] = 0
end
function _auto_name()
    _name_counter[] += 1
    Symbol("__v$(_name_counter[])")
end

# ---- module walking ----

function _module_to_parsed_ir(mod::LLVM.Module)
    _reset_names!()

    # Find the julia_ function with a body
    func = nothing
    for f in LLVM.functions(mod)
        if startswith(LLVM.name(f), "julia_") && !isempty(LLVM.blocks(f))
            func = f
            break
        end
    end
    func === nothing && error("No julia_ function found in LLVM module")

    # Return type (scalar integer or array of integers)
    ft = LLVM.function_type(func)
    rt = LLVM.return_type(ft)
    ret_width = _type_width(rt)
    ret_elem_widths = if rt isa LLVM.ArrayType
        [LLVM.width(LLVM.eltype(rt)) for _ in 1:LLVM.length(rt)]
    else
        [ret_width]
    end

    # Build name table: LLVMValueRef → Symbol  (two-pass: name everything first)
    names = Dict{_LLVMRef, Symbol}()

    # Name parameters
    args = Tuple{Symbol,Int}[]
    # Track pointer params: map ptr SSA name → (base_sym, byte_size) for GEP/load resolution
    ptr_params = Dict{Symbol, Tuple{Symbol, Int}}()
    for p in LLVM.parameters(func)
        nm = LLVM.name(p)
        sym = isempty(nm) ? _auto_name() : Symbol(nm)
        names[p.ref] = sym
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
            names[inst.ref] = isempty(nm) ? _auto_name() : Symbol(nm)
        end
    end

    # Convert blocks (second pass)
    blocks = IRBasicBlock[]
    for bb in LLVM.blocks(func)
        label = Symbol(LLVM.name(bb))
        insts = IRInst[]
        terminator = nothing

        for inst in LLVM.instructions(bb)
            ir_inst = _convert_instruction(inst, names)
            ir_inst === nothing && continue
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

        terminator === nothing && error("Block $label has no terminator")
        push!(blocks, IRBasicBlock(label, insts, terminator))
    end

    # Post-pass: expand switch terminators into cascaded icmp + branch blocks
    blocks = _expand_switches(blocks)

    return ParsedIR(ret_width, args, blocks, ret_elem_widths)
end

"""
Expand IRSwitch terminators into cascaded comparison blocks.

switch val, default [c1 → L1, c2 → L2, ...] becomes:

    _sw_0: icmp eq val, c1 → br (L1, _sw_1)
    _sw_1: icmp eq val, c2 → br (L2, _sw_2)
    ...
    _sw_N: unconditional br → default

Phi nodes in target blocks are updated to reference the new synthetic blocks
instead of the original switch block.
"""
function _expand_switches(blocks::Vector{IRBasicBlock})
    result = IRBasicBlock[]
    for block in blocks
        if !(block.terminator isa IRSwitch)
            push!(result, block)
            continue
        end

        sw = block.terminator
        orig_label = block.label
        n_cases = length(sw.cases)

        if n_cases == 0
            # Degenerate: just unconditional branch to default
            push!(result, IRBasicBlock(orig_label, block.instructions,
                                       IRBranch(nothing, sw.default_label, nothing)))
            continue
        end

        # Generate synthetic block labels
        syn_labels = [Symbol("_sw_$(orig_label)_$i") for i in 1:n_cases]

        # First block: original block with first comparison
        cmp_dest_1 = Symbol("_sw_cmp_$(orig_label)_1")
        first_cmp = IRICmp(cmp_dest_1, :eq, sw.cond, sw.cases[1][1], sw.cond_width)
        first_br = IRBranch(ssa(cmp_dest_1), sw.cases[1][2],
                            n_cases >= 2 ? syn_labels[2] : sw.default_label)
        push!(result, IRBasicBlock(orig_label,
                                   vcat(block.instructions, [first_cmp]),
                                   first_br))

        # Middle comparison blocks (cases 2..N-1)
        for i in 2:(n_cases - 1)
            cmp_dest = Symbol("_sw_cmp_$(orig_label)_$i")
            cmp = IRICmp(cmp_dest, :eq, sw.cond, sw.cases[i][1], sw.cond_width)
            br = IRBranch(ssa(cmp_dest), sw.cases[i][2], syn_labels[i + 1])
            push!(result, IRBasicBlock(syn_labels[i], [cmp], br))
        end

        # Last comparison block (case N)
        if n_cases >= 2
            cmp_dest_n = Symbol("_sw_cmp_$(orig_label)_$n_cases")
            cmp_n = IRICmp(cmp_dest_n, :eq, sw.cond, sw.cases[n_cases][1], sw.cond_width)
            br_n = IRBranch(ssa(cmp_dest_n), sw.cases[n_cases][2], sw.default_label)
            push!(result, IRBasicBlock(syn_labels[n_cases], [cmp_n], br_n))
        end

        # Update phi nodes: replace references to orig_label with the
        # correct synthetic block that actually branches to the target.
        # For case i → target Li, the branch comes from:
        #   case 1: orig_label, case 2..N: syn_labels[i], default: syn_labels[N]
        phi_remap = Dict{Symbol, Symbol}()  # target_label => source block
        phi_remap[sw.cases[1][2]] = orig_label
        for i in 2:n_cases
            phi_remap[sw.cases[i][2]] = syn_labels[i]
        end
        phi_remap[sw.default_label] = n_cases >= 2 ? syn_labels[n_cases] : orig_label

        # Patch phi nodes in all blocks that reference orig_label
        for j in eachindex(result)
            blk = result[j]
            new_insts = IRInst[]
            changed = false
            for inst in blk.instructions
                if inst isa IRPhi
                    new_incoming = Tuple{IROperand, Symbol}[]
                    for (val, from_block) in inst.incoming
                        if from_block == orig_label
                            # Find which synthetic block branches to this phi's block
                            actual_from = get(phi_remap, blk.label, from_block)
                            push!(new_incoming, (val, actual_from))
                            changed = true
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

# ---- instruction conversion ----

function _convert_instruction(inst::LLVM.Instruction, names::Dict{_LLVMRef, Symbol})
    opc = LLVM.opcode(inst)
    dest = names[inst.ref]

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
        ops = LLVM.operands(inst)
        return IRICmp(dest, _pred_to_sym(LLVM.predicate(inst)),
                      _operand(ops[1], names), _operand(ops[2], names),
                      _iwidth(ops[1]))
    end

    # select
    if opc == LLVM.API.LLVMSelect
        ops = LLVM.operands(inst)
        return IRSelect(dest, _operand(ops[1], names),
                        _operand(ops[2], names), _operand(ops[3], names),
                        _iwidth(inst))
    end

    # phi
    if opc == LLVM.API.LLVMPHI
        incoming = Tuple{IROperand, Symbol}[]
        for (val, blk) in LLVM.incoming(inst)
            push!(incoming, (_operand(val, names), Symbol(LLVM.name(blk))))
        end
        return IRPhi(dest, _iwidth(inst), incoming)
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
        return IRRet(_operand(ops[1], names), _iwidth(ops[1]))
    end

    # extractvalue — select one element from an aggregate
    if opc == LLVM.API.LLVMExtractValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        idx_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = unsafe_load(idx_ptr)  # 0-based
        agg_type = LLVM.value_type(agg_val)
        ew = LLVM.width(LLVM.eltype(agg_type))
        ne = LLVM.length(agg_type)
        return IRExtractValue(dest, _operand(agg_val, names), idx, ew, ne)
    end

    # insertvalue
    if opc == LLVM.API.LLVMInsertValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        elem_val = ops[2]
        idxs_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = Int(unsafe_wrap(Array, idxs_ptr, 1)[1])
        agg_type = LLVM.value_type(inst)
        ew = LLVM.width(LLVM.eltype(agg_type))
        ne = LLVM.length(agg_type)
        return IRInsertValue(dest, _operand(agg_val, names),
                             _operand(elem_val, names), idx, ew, ne)
    end

    # unreachable — dead code
    if opc == LLVM.API.LLVMUnreachable
        return IRBranch(nothing, :__unreachable__, nothing)
    end

    # call instructions: handle known LLVM intrinsics, skip the rest
    if opc == LLVM.API.LLVMCall
        ops = LLVM.operands(inst)
        n_ops = length(ops)
        if n_ops >= 1
            cname = try LLVM.name(ops[n_ops]) catch; "" end
            if startswith(cname, "llvm.umax")
                cmp_dest = _auto_name()
                w = _iwidth(ops[1])
                return [
                    IRICmp(cmp_dest, :uge, _operand(ops[1], names), _operand(ops[2], names), w),
                    IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
                ]
            end
            if startswith(cname, "llvm.umin")
                cmp_dest = _auto_name()
                w = _iwidth(ops[1])
                return [
                    IRICmp(cmp_dest, :ule, _operand(ops[1], names), _operand(ops[2], names), w),
                    IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
                ]
            end
            if startswith(cname, "llvm.smax")
                cmp_dest = _auto_name()
                w = _iwidth(ops[1])
                return [
                    IRICmp(cmp_dest, :sge, _operand(ops[1], names), _operand(ops[2], names), w),
                    IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
                ]
            end
            if startswith(cname, "llvm.smin")
                cmp_dest = _auto_name()
                w = _iwidth(ops[1])
                return [
                    IRICmp(cmp_dest, :sle, _operand(ops[1], names), _operand(ops[2], names), w),
                    IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
                ]
            end
            # llvm.abs.iN(x, is_int_min_poison) = x >= 0 ? x : 0 - x
            if startswith(cname, "llvm.abs")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                neg_dest = _auto_name()
                cmp_dest = _auto_name()
                return [
                    IRBinOp(neg_dest, :sub, iconst(0), x_op, w),
                    IRICmp(cmp_dest, :sge, x_op, iconst(0), w),
                    IRSelect(dest, ssa(cmp_dest), x_op, ssa(neg_dest), w),
                ]
            end
            # llvm.ctpop.iN(x) = popcount(x)
            # Expand: sum of individual bits via cascaded add
            if startswith(cname, "llvm.ctpop")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                result = IRInst[]
                # Extract each bit: bit_i = (x >> i) & 1
                # Then sum them up: result = bit_0 + bit_1 + ... + bit_{W-1}
                prev = _auto_name()
                push!(result, IRBinOp(prev, :and, x_op, iconst(1), w))
                for i in 1:(w - 1)
                    shifted = _auto_name()
                    bit = _auto_name()
                    acc = _auto_name()
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
            if startswith(cname, "llvm.ctlz")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                result = IRInst[]
                prev = _auto_name()
                push!(result, IRBinOp(prev, :add, iconst(w), iconst(0), w))  # default: W (all zeros)
                for i in 0:(w - 1)  # LSB to MSB; last match = highest bit = correct clz
                    shifted = _auto_name()
                    bit = _auto_name()
                    is_set = _auto_name()
                    new_val = _auto_name()
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
            if startswith(cname, "llvm.cttz")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                result = IRInst[]
                prev = _auto_name()
                push!(result, IRBinOp(prev, :add, iconst(w), iconst(0), w))
                for i in (w - 1):-1:0  # MSB to LSB; last match = lowest bit = correct ctz
                    shifted = _auto_name()
                    bit = _auto_name()
                    is_set = _auto_name()
                    new_val = _auto_name()
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
            if startswith(cname, "llvm.bitreverse")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                result = IRInst[]
                # bit_i → position (W-1-i): shift right by i, mask, shift left by (W-1-i)
                prev = _auto_name()
                # First bit
                shifted0 = _auto_name()
                push!(result, IRBinOp(shifted0, :lshr, x_op, iconst(0), w))
                push!(result, IRBinOp(prev, :and, ssa(shifted0), iconst(1), w))
                shl0 = _auto_name()
                push!(result, IRBinOp(shl0, :shl, ssa(prev), iconst(w - 1), w))
                prev = shl0
                for i in 1:(w - 1)
                    shifted = _auto_name()
                    bit = _auto_name()
                    placed = _auto_name()
                    acc = _auto_name()
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
            if startswith(cname, "llvm.bswap")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                n_bytes = w ÷ 8
                result = IRInst[]
                # Extract each byte, shift to swapped position, OR together
                prev = _auto_name()
                byte0 = _auto_name()
                push!(result, IRBinOp(byte0, :and, x_op, iconst(255), w))
                push!(result, IRBinOp(prev, :shl, ssa(byte0), iconst((n_bytes - 1) * 8), w))
                for b in 1:(n_bytes - 1)
                    shifted = _auto_name()
                    byte_val = _auto_name()
                    placed = _auto_name()
                    acc = _auto_name()
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
            if startswith(cname, "llvm.fshl")
                w = _iwidth(ops[1])
                a_op = _operand(ops[1], names)
                b_op = _operand(ops[2], names)
                sh_op = _operand(ops[3], names)
                shl_dest = _auto_name()
                lshr_dest = _auto_name()
                if sh_op.kind == :const
                    # Constant-fold: w - const is const (no runtime sub needed)
                    return [
                        IRBinOp(shl_dest, :shl, a_op, sh_op, w),
                        IRBinOp(lshr_dest, :lshr, b_op, iconst(w - sh_op.value), w),
                        IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
                    ]
                else
                    rsh_amount = _auto_name()
                    return [
                        IRBinOp(shl_dest, :shl, a_op, sh_op, w),
                        IRBinOp(rsh_amount, :sub, iconst(w), sh_op, w),
                        IRBinOp(lshr_dest, :lshr, b_op, ssa(rsh_amount), w),
                        IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
                    ]
                end
            end
            # llvm.fshr.i64(a, b, shift) = (a << (64 - shift)) | (b >> shift)
            if startswith(cname, "llvm.fshr")
                w = _iwidth(ops[1])
                a_op = _operand(ops[1], names)
                b_op = _operand(ops[2], names)
                sh_op = _operand(ops[3], names)
                shl_dest = _auto_name()
                lshr_dest = _auto_name()
                if sh_op.kind == :const
                    # Constant-fold: w - const is const
                    return [
                        IRBinOp(shl_dest, :shl, a_op, iconst(w - sh_op.value), w),
                        IRBinOp(lshr_dest, :lshr, b_op, sh_op, w),
                        IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
                    ]
                else
                    shl_amount = _auto_name()
                    return [
                        IRBinOp(shl_amount, :sub, iconst(w), sh_op, w),
                        IRBinOp(shl_dest, :shl, a_op, ssa(shl_amount), w),
                        IRBinOp(lshr_dest, :lshr, b_op, sh_op, w),
                        IRBinOp(dest, :or, ssa(shl_dest), ssa(lshr_dest), w),
                    ]
                end
            end
            # llvm.fabs: clear sign bit (AND with ~sign_bit)
            if startswith(cname, "llvm.fabs")
                w = _iwidth(ops[1])
                mask = w == 64 ? typemax(Int64) : Int((1 << (w - 1)) - 1)
                return IRBinOp(dest, :and, _operand(ops[1], names), iconst(mask), w)
            end
            # llvm.copysign: (x AND ~sign_bit) OR (y AND sign_bit)
            if startswith(cname, "llvm.copysign")
                w = _iwidth(ops[1])
                mag_mask = w == 64 ? typemax(Int64) : Int((1 << (w - 1)) - 1)
                sign_bit = w == 64 ? typemin(Int64) : Int(1 << (w - 1))
                x_op = _operand(ops[1], names)
                y_op = _operand(ops[2], names)
                mag = _auto_name()
                sgn = _auto_name()
                return [
                    IRBinOp(mag, :and, x_op, iconst(mag_mask), w),
                    IRBinOp(sgn, :and, y_op, iconst(sign_bit), w),
                    IRBinOp(dest, :or, ssa(mag), ssa(sgn), w),
                ]
            end
            # llvm.floor / llvm.ceil / llvm.trunc / llvm.rint / llvm.round
            if startswith(cname, "llvm.floor") || startswith(cname, "llvm.ceil") ||
               startswith(cname, "llvm.trunc") || startswith(cname, "llvm.rint") ||
               startswith(cname, "llvm.round")
                # Route through soft_floor/ceil/trunc via SoftFloat dispatch
                # These are handled by the callee registry (registered soft_floor etc.)
                # At the LLVM level, these operate on native floats — but in the
                # SoftFloat wrapper path, Julia dispatches to our SoftFloat methods
                # which call soft_floor/ceil/trunc on UInt64. Those are registered
                # callees, so ir_extract picks them up via _lookup_callee.
                # Skip: let the standard callee path handle it.
            end
            # llvm.minnum / llvm.maxnum / llvm.minimum / llvm.maximum
            if startswith(cname, "llvm.minnum") || startswith(cname, "llvm.minimum")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                y_op = _operand(ops[2], names)
                cmp = _auto_name()
                return [
                    IRICmp(cmp, :slt, x_op, y_op, w),
                    IRSelect(dest, ssa(cmp), x_op, y_op, w),
                ]
            end
            if startswith(cname, "llvm.maxnum") || startswith(cname, "llvm.maximum")
                w = _iwidth(ops[1])
                x_op = _operand(ops[1], names)
                y_op = _operand(ops[2], names)
                cmp = _auto_name()
                return [
                    IRICmp(cmp, :sgt, x_op, y_op, w),
                    IRSelect(dest, ssa(cmp), x_op, y_op, w),
                ]
            end
        end
        # Known Julia function calls → IRCall for gate-level inlining
        if n_ops >= 1
            callee = _lookup_callee(cname)
            if callee !== nothing
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
        return nothing
    end

    # GEP with constant or variable offset
    if opc == LLVM.API.LLVMGetElementPtr
        ops = LLVM.operands(inst)
        base = ops[1]
        if haskey(names, base.ref) && length(ops) == 2
            if ops[2] isa LLVM.ConstantInt
                # Constant-index GEP → IRPtrOffset (wire selection from flat array)
                offset = convert(Int, ops[2])
                return IRPtrOffset(dest, ssa(names[base.ref]), offset)
            else
                # Variable-index GEP → IRVarGEP (MUX-tree selection at lowering time)
                idx_op = _operand(ops[2], names)
                src_ty_ref = LLVM.API.LLVMGetGEPSourceElementType(inst)
                src_type = LLVM.LLVMType(src_ty_ref)
                ew = src_type isa LLVM.IntegerType ? LLVM.width(src_type) : 8
                return IRVarGEP(dest, ssa(names[base.ref]), idx_op, ew)
            end
        end
        return nothing  # GEP with unknown base — skip
    end

    # Load from pointer → IRLoad (CNOT-copy from wire subset)
    if opc == LLVM.API.LLVMLoad
        ops = LLVM.operands(inst)
        ptr = ops[1]
        if haskey(names, ptr.ref)
            rt = LLVM.value_type(inst)
            if rt isa LLVM.IntegerType
                return IRLoad(dest, ssa(names[ptr.ref]), LLVM.width(rt))
            end
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
            case_int = convert(Int, case_val)
            case_op = IROperand(:const, Symbol(string(case_int)), case_int)
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

    # fptosi/fptoui: float → int conversion via soft_fptosi (actual IEEE 754 decode)
    if opc in (LLVM.API.LLVMFPToSI, LLVM.API.LLVMFPToUI)
        src = LLVM.operands(inst)[1]
        src_w = _iwidth(src)
        dst_w = _iwidth(inst)
        callee = _lookup_callee("soft_fptosi")
        if callee !== nothing && src_w == 64
            # Route through soft_fptosi for Float64→Int64 conversion
            call_result = IRCall(dest, callee, [_operand(src, names)], [src_w], dst_w)
            if dst_w == src_w
                return call_result
            else
                # Need to truncate the 64-bit result to the target width
                trunc_dest = dest
                call_dest = _auto_name()
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
                widen_dest = _auto_name()
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
        else
            error("Unsupported fcmp predicate: $pred_int in $(string(inst))")
        end
        callee === nothing && error("soft_fcmp callee not registered for fcmp predicate $pred_int")
        # soft_fcmp returns UInt64 (0 or 1), but fcmp result is i1.
        # Use IRCall with ret_width=1 and let lowering truncate.
        call_dest = _auto_name()
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
        src_w == dst_w || error("bitcast width mismatch: $src_w → $dst_w")
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

    # skip known-safe no-op instructions
    if opc in (LLVM.API.LLVMStore, LLVM.API.LLVMAlloca)
        return nothing
    end

    error("Unsupported LLVM opcode: $opc in instruction: $(string(inst))")
end

# ---- helpers ----

"""Get the dereferenceable byte count from a pointer parameter, or 0 if unknown."""
function _get_deref_bytes(func::LLVM.Function, param::LLVM.Argument)
    # Find the parameter index (1-based)
    idx = findfirst(p -> p.ref == param.ref, collect(LLVM.parameters(func)))
    idx === nothing && return 0
    # Check parameter attributes for dereferenceable(N)
    try
        for attr in LLVM.parameter_attributes(func, idx)
            s = string(attr)
            m = match(r"dereferenceable\((\d+)\)", s)
            if m !== nothing
                return parse(Int, m.captures[1])
            end
        end
    catch e
        e isa MethodError || rethrow()
    end
    # Fallback: parse from function definition line
    ir_str = string(func)
    # Match "dereferenceable(N) %paramname" pattern
    pname = LLVM.name(param)
    # Look for dereferenceable(N) near the param name on the define line
    defline = split(ir_str, "\n")[1]
    m = match(r"dereferenceable\((\d+)\)", defline)
    if m !== nothing
        return parse(Int, m.captures[1])
    end
    return 0
end

function _operand(val::LLVM.Value, names::Dict{_LLVMRef, Symbol})
    if val isa LLVM.ConstantInt
        return iconst(convert(Int, val))
    elseif val isa LLVM.ConstantAggregateZero
        return IROperand(:const, :__zero_agg__, 0)  # special: zero aggregate
    else
        r = val.ref
        haskey(names, r) || error("Unknown operand ref for: $(string(val))")
        return ssa(names[r])
    end
end

function _iwidth(val)
    tp = LLVM.value_type(val)
    _type_width(tp)
end

function _type_width(tp)
    if tp isa LLVM.IntegerType
        return LLVM.width(tp)
    elseif tp isa LLVM.ArrayType
        return LLVM.length(tp) * _type_width(LLVM.eltype(tp))
    elseif tp isa LLVM.FloatingPointType
        # IEEE 754: half=16, float=32, double=64
        tp isa LLVM.LLVMDouble && return 64
        tp isa LLVM.LLVMFloat  && return 32
        tp isa LLVM.LLVMHalf   && return 16
        error("Unsupported float type: $tp")
    else
        error("Unsupported LLVM type for width: $tp")
    end
end

const _OPCODE_MAP = Dict(
    LLVM.API.LLVMAdd  => :add,  LLVM.API.LLVMSub  => :sub,
    LLVM.API.LLVMMul  => :mul,  LLVM.API.LLVMAnd  => :and,
    LLVM.API.LLVMOr   => :or,   LLVM.API.LLVMXor  => :xor,
    LLVM.API.LLVMShl  => :shl,  LLVM.API.LLVMLShr => :lshr,
    LLVM.API.LLVMAShr => :ashr,
)
_opcode_to_sym(opc) = _OPCODE_MAP[opc]

const _PRED_MAP = Dict(
    LLVM.API.LLVMIntEQ  => :eq,  LLVM.API.LLVMIntNE  => :ne,
    LLVM.API.LLVMIntULT => :ult, LLVM.API.LLVMIntUGT => :ugt,
    LLVM.API.LLVMIntULE => :ule, LLVM.API.LLVMIntUGE => :uge,
    LLVM.API.LLVMIntSLT => :slt, LLVM.API.LLVMIntSGT => :sgt,
    LLVM.API.LLVMIntSLE => :sle, LLVM.API.LLVMIntSGE => :sge,
)
_pred_to_sym(pred) = _PRED_MAP[pred]
