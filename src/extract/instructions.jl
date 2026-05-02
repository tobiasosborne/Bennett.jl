# ---- instruction conversion ----

# Bennett-tzrs / U41 (first-cut, 2026-04-27): the LLVM-intrinsic prefix
# dispatch was lifted out of `_convert_instruction`'s 836-line body into
# this helper. Order of `if startswith(cname, "...")` branches is LOAD-
# BEARING — `llvm.minnum` / `llvm.minimum` and `llvm.maxnum` / `llvm.maximum`
# share handlers via prefix-match, and the floor/ceil/trunc/rint/round
# branch is INTENTIONALLY a no-op (it lets the registered-callee path in
# `_convert_instruction` pick up `soft_floor` / `soft_ceil` / etc. via
# the SoftFloat dispatch). Returns `nothing` if no intrinsic matched —
# the call site then proceeds to the registered-callee lookup and the
# benign-allowlist guard. Per CLAUDE.md §2 this is part of the 3+1-mandated
# tzrs refactor (proposers: A and B; orchestrator: tobias 2026-04-27).
function _handle_intrinsic(cname::AbstractString, inst::LLVM.Instruction,
                           names::Dict{_LLVMRef, Symbol}, counter::Ref{Int},
                           dest::Symbol, ops)
    if startswith(cname, "llvm.umax")
        cmp_dest = _auto_name(counter)
        w = _iwidth(ops[1])
        return [
            IRICmp(cmp_dest, :uge, _operand(ops[1], names), _operand(ops[2], names), w),
            IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
        ]
    end
    if startswith(cname, "llvm.umin")
        cmp_dest = _auto_name(counter)
        w = _iwidth(ops[1])
        return [
            IRICmp(cmp_dest, :ule, _operand(ops[1], names), _operand(ops[2], names), w),
            IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
        ]
    end
    if startswith(cname, "llvm.smax")
        cmp_dest = _auto_name(counter)
        w = _iwidth(ops[1])
        return [
            IRICmp(cmp_dest, :sge, _operand(ops[1], names), _operand(ops[2], names), w),
            IRSelect(dest, ssa(cmp_dest), _operand(ops[1], names), _operand(ops[2], names), w)
        ]
    end
    if startswith(cname, "llvm.smin")
        cmp_dest = _auto_name(counter)
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
    if startswith(cname, "llvm.ctpop")
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
    if startswith(cname, "llvm.ctlz")
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
    if startswith(cname, "llvm.cttz")
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
    if startswith(cname, "llvm.bitreverse")
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
    if startswith(cname, "llvm.bswap")
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
    if startswith(cname, "llvm.fshl")
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
    if startswith(cname, "llvm.fshr")
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
        mag = _auto_name(counter)
        sgn = _auto_name(counter)
        return [
            IRBinOp(mag, :and, x_op, iconst(mag_mask), w),
            IRBinOp(sgn, :and, y_op, iconst(sign_bit), w),
            IRBinOp(dest, :or, ssa(mag), ssa(sgn), w),
        ]
    end
    # llvm.floor / llvm.ceil / llvm.trunc / llvm.rint / llvm.round
    # Intentionally NO return: the registered-callee path in
    # `_convert_instruction` picks these up via SoftFloat dispatch
    # (`soft_floor` / `soft_ceil` / `soft_trunc` are registered callees).
    # Falling through to the next `if` keeps the original semantics.
    if startswith(cname, "llvm.floor") || startswith(cname, "llvm.ceil") ||
       startswith(cname, "llvm.trunc") || startswith(cname, "llvm.rint") ||
       startswith(cname, "llvm.round")
        # No-op: handled by callee registry
    end
    # llvm.minnum / llvm.maxnum / llvm.minimum / llvm.maximum
    if startswith(cname, "llvm.minnum") || startswith(cname, "llvm.minimum")
        w = _iwidth(ops[1])
        x_op = _operand(ops[1], names)
        y_op = _operand(ops[2], names)
        cmp = _auto_name(counter)
        return [
            IRICmp(cmp, :slt, x_op, y_op, w),
            IRSelect(dest, ssa(cmp), x_op, y_op, w),
        ]
    end
    if startswith(cname, "llvm.maxnum") || startswith(cname, "llvm.maximum")
        w = _iwidth(ops[1])
        x_op = _operand(ops[1], names)
        y_op = _operand(ops[2], names)
        cmp = _auto_name(counter)
        return [
            IRICmp(cmp, :sgt, x_op, y_op, w),
            IRSelect(dest, ssa(cmp), x_op, y_op, w),
        ]
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
    if startswith(cname, "llvm.sqrt")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.sqrt: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-1pb)")
        return IRCall(dest, soft_fsqrt, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.exp2")
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
    if startswith(cname, "llvm.fma") || startswith(cname, "llvm.fmuladd")
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
    if startswith(cname, "llvm.exp")
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
    if startswith(cname, "llvm.log10")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log10: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-582)")
        return IRCall(dest, soft_log10, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.log2")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log2: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-582)")
        return IRCall(dest, soft_log2, [_operand(ops[1], names)], [w], w)
    end
    if startswith(cname, "llvm.log")
        w = _iwidth(ops[1])
        w == 64 || _ir_error(inst,
            "llvm.log: only f64 supported (got width=$w); native " *
            "f32/f16 transcendentals are not bit-exact (CLAUDE.md §13). " *
            "(Bennett-582)")
        return IRCall(dest, soft_log, [_operand(ops[1], names)], [w], w)
    end
    return nothing
end

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
function _convert_instruction(inst::LLVM.Instruction, names::Dict{_LLVMRef, Symbol},
                              counter::Ref{Int},
                              lanes::Dict{_LLVMRef, Vector{IROperand}}=Dict{_LLVMRef, Vector{IROperand}}())
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
        ops = LLVM.operands(inst)
        return IRICmp(dest, _pred_to_sym(LLVM.predicate(inst)),
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
            push!(incoming, (_operand(val, names), Symbol(LLVM.name(blk))))
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

    # extractvalue — select one element from an aggregate.
    # Bennett-tu6i / U10: only ArrayType aggregates are supported (homogeneous,
    # scalar-element). StructType aggregates ({iN, i1}, mixed-width tuples,
    # .with.overflow intrinsics, cmpxchg results) need field-wise width
    # tracking that IRExtractValue doesn't carry. Fail loud on StructType —
    # without this guard, `LLVM.eltype(struct_type)` raises a raw UndefRefError
    # deep in the LLVM.jl bindings with no Bennett context.
    if opc == LLVM.API.LLVMExtractValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        idx_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = unsafe_load(idx_ptr)  # 0-based
        agg_type = LLVM.value_type(agg_val)
        agg_type isa LLVM.ArrayType || _ir_error(inst,
            "extractvalue on StructType aggregates not supported; " *
            "only homogeneous ArrayType aggregates are. Source type: " *
            string(agg_type))
        ew = LLVM.width(LLVM.eltype(agg_type))
        ne = LLVM.length(agg_type)
        return IRExtractValue(dest, _operand(agg_val, names), idx, ew, ne)
    end

    # insertvalue — same ArrayType-only restriction as extractvalue.
    if opc == LLVM.API.LLVMInsertValue
        ops = LLVM.operands(inst)
        agg_val = ops[1]
        elem_val = ops[2]
        idxs_ptr = LLVM.API.LLVMGetIndices(inst)
        idx = Int(unsafe_wrap(Array, idxs_ptr, 1)[1])
        agg_type = LLVM.value_type(inst)
        agg_type isa LLVM.ArrayType || _ir_error(inst,
            "insertvalue on StructType aggregates not supported; " *
            "only homogeneous ArrayType aggregates are. Destination type: " *
            string(agg_type))
        ew = LLVM.width(LLVM.eltype(agg_type))
        ne = LLVM.length(agg_type)
        return IRInsertValue(dest, _operand(agg_val, names),
                             _operand(elem_val, names), idx, ew, ne)
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
            handled = _handle_intrinsic(cname, inst, names, counter, dest, ops)
            handled === nothing || return handled
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
            # llvm.memset appears in Julia IR for GC-frame zeroing etc.;
            # reversible pipeline treats allocations separately.
            "llvm.memset",
            # llvm.memcpy's sret-specific path is handled upstream via
            # auto-SROA (Bennett-uyf9 / γ); non-sret forms are rare in
            # our corpus and route through the same benign-drop gate.
            "llvm.memcpy",
            "llvm.memmove",
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
        # Unregistered callee or unrecognised intrinsic.
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
                offset = if src_type_const isa LLVM.IntegerType
                    stride_bytes = LLVM.width(src_type_const) ÷ 8
                    stride_bytes >= 1 || _ir_error(inst,
                        "constant-index GEP with sub-byte source element " *
                        "width $(LLVM.width(src_type_const)) bits not " *
                        "supported (Bennett-vz5n / U12)")
                    raw_idx * stride_bytes
                else
                    # Struct / array / float / vector base: legacy raw-index
                    # behaviour. Silent-pass, tracked in U16.
                    raw_idx
                end
                return IRPtrOffset(dest, ssa(names[base.ref]), offset)
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
        LLVM.API.LLVMGetVolatile(inst) == 0 || _ir_error(inst,
            "volatile load not supported (Bennett-4mmt / U14)")
        LLVM.API.LLVMGetOrdering(inst) == LLVM.API.LLVMAtomicOrderingNotAtomic ||
            _ir_error(inst,
                "atomic load not supported (Bennett-4mmt / U14)")
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
        LLVM.API.LLVMGetVolatile(inst) == 0 || _ir_error(inst,
            "volatile store not supported (Bennett-4mmt / U14)")
        LLVM.API.LLVMGetOrdering(inst) == LLVM.API.LLVMAtomicOrderingNotAtomic ||
            _ir_error(inst,
                "atomic store not supported (Bennett-4mmt / U14)")
        ops = LLVM.operands(inst)
        val = ops[1]
        ptr = ops[2]
        vt = LLVM.value_type(val)
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
        elem_ty = LLVM.LLVMType(LLVM.API.LLVMGetAllocatedType(inst.ref))
        elem_ty isa LLVM.IntegerType || return nothing
        elem_w = LLVM.width(elem_ty)
        ops = LLVM.operands(inst)
        n_elems_op = if !isempty(ops) && ops[1] isa LLVM.ConstantInt
            iconst(_const_int_as_int(ops[1]))
        elseif !isempty(ops) && haskey(names, ops[1].ref)
            ssa(names[ops[1].ref])
        else
            iconst(1)  # scalar alloca with no explicit count
        end
        return IRAlloca(dest, elem_w, n_elems_op)
    end

    _ir_error(inst, "unsupported LLVM opcode")
end

