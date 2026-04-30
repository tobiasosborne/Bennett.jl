# ---- Bennett-cc0.6: standardized error reporting ----
#
# When an unsupported LLVM IR pattern fires an error, the message should
# tell the debugger exactly where to look in the IR: function name, block
# label, and the full stringified instruction. Canonical format:
#
#   ir_extract.jl: <opcode> in @<funcname>:%<blockname>: <serialised> — <reason>
#
# `_ir_error(inst, reason)` raises in this format. Callers that have an
# `inst::LLVM.Instruction` in scope should prefer this helper over a raw
# `error(...)`. Helper-level errors (in `_operand`, `_fold_constexpr_operand`,
# `_resolve_vec_lanes`, etc.) keep their value-scoped messages — the stack
# trace shows the enclosing instruction.

# Opcode-enum → human-readable name. Falls back to `string(opc)`.
const _LLVM_OPCODE_NAMES = Dict(
    LLVM.API.LLVMRet            => "ret",
    LLVM.API.LLVMBr             => "br",
    LLVM.API.LLVMSwitch         => "switch",
    LLVM.API.LLVMIndirectBr     => "indirectbr",
    LLVM.API.LLVMInvoke         => "invoke",
    LLVM.API.LLVMUnreachable    => "unreachable",
    LLVM.API.LLVMAdd            => "add",
    LLVM.API.LLVMFAdd           => "fadd",
    LLVM.API.LLVMSub            => "sub",
    LLVM.API.LLVMFSub           => "fsub",
    LLVM.API.LLVMMul            => "mul",
    LLVM.API.LLVMFMul           => "fmul",
    LLVM.API.LLVMUDiv           => "udiv",
    LLVM.API.LLVMSDiv           => "sdiv",
    LLVM.API.LLVMFDiv           => "fdiv",
    LLVM.API.LLVMURem           => "urem",
    LLVM.API.LLVMSRem           => "srem",
    LLVM.API.LLVMFRem           => "frem",
    LLVM.API.LLVMShl            => "shl",
    LLVM.API.LLVMLShr           => "lshr",
    LLVM.API.LLVMAShr           => "ashr",
    LLVM.API.LLVMAnd            => "and",
    LLVM.API.LLVMOr             => "or",
    LLVM.API.LLVMXor            => "xor",
    LLVM.API.LLVMAlloca         => "alloca",
    LLVM.API.LLVMLoad           => "load",
    LLVM.API.LLVMStore          => "store",
    LLVM.API.LLVMGetElementPtr  => "getelementptr",
    LLVM.API.LLVMTrunc          => "trunc",
    LLVM.API.LLVMZExt           => "zext",
    LLVM.API.LLVMSExt           => "sext",
    LLVM.API.LLVMFPToUI         => "fptoui",
    LLVM.API.LLVMFPToSI         => "fptosi",
    LLVM.API.LLVMUIToFP         => "uitofp",
    LLVM.API.LLVMSIToFP         => "sitofp",
    LLVM.API.LLVMFPTrunc        => "fptrunc",
    LLVM.API.LLVMFPExt          => "fpext",
    LLVM.API.LLVMPtrToInt       => "ptrtoint",
    LLVM.API.LLVMIntToPtr       => "inttoptr",
    LLVM.API.LLVMBitCast        => "bitcast",
    LLVM.API.LLVMAddrSpaceCast  => "addrspacecast",
    LLVM.API.LLVMICmp           => "icmp",
    LLVM.API.LLVMFCmp           => "fcmp",
    LLVM.API.LLVMPHI            => "phi",
    LLVM.API.LLVMCall           => "call",
    LLVM.API.LLVMSelect         => "select",
    LLVM.API.LLVMExtractValue   => "extractvalue",
    LLVM.API.LLVMInsertValue    => "insertvalue",
    LLVM.API.LLVMExtractElement => "extractelement",
    LLVM.API.LLVMInsertElement  => "insertelement",
    LLVM.API.LLVMShuffleVector  => "shufflevector",
    LLVM.API.LLVMFNeg           => "fneg",
    LLVM.API.LLVMFence          => "fence",
    LLVM.API.LLVMFreeze         => "freeze",
)

_llvm_opcode_name(opc) = get(_LLVM_OPCODE_NAMES, opc, string(opc))

# Build the canonical error message for an instruction-scoped failure.
# Each LLVM.* introspection call is wrapped: if the C-API errors on a
# freed/invalid value during error formatting we still want to produce a
# message rather than crash with a different exception. Bennett-uinn / U93:
# narrow each catch to re-raise InterruptException so Ctrl-C still works.
function _ir_error_msg(inst::LLVM.Instruction, reason::AbstractString)::String
    opc_name = try
        _llvm_opcode_name(LLVM.opcode(inst))
    catch e
        e isa InterruptException && rethrow()
        "unknown-opcode"
    end
    bb = try
        LLVM.parent(inst)
    catch e
        e isa InterruptException && rethrow()
        nothing
    end
    fname = bb === nothing ? "<unknown-fn>" : try
        LLVM.name(LLVM.parent(bb))
    catch e
        e isa InterruptException && rethrow()
        "<unknown-fn>"
    end
    bname = bb === nothing ? "<unknown-block>" : try
        LLVM.name(bb)
    catch e
        e isa InterruptException && rethrow()
        "<unknown-block>"
    end
    inst_str = try
        string(inst)
    catch e
        e isa InterruptException && rethrow()
        "<unprintable-instruction>"
    end
    return "ir_extract.jl: $opc_name in @$fname:%$bname: $inst_str — $reason"
end

# Raise a standardized error for an instruction-scoped failure.
function _ir_error(inst::LLVM.Instruction, reason::AbstractString)
    error(_ir_error_msg(inst, reason))
end

