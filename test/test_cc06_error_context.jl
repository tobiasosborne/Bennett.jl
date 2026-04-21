using Test
using Bennett

# Bennett-cc0.6 — standardized error-message format for ir_extract.jl.
#
# When ir_extract crashes on an unsupported LLVM IR pattern, the error
# message should include enough context for a debugger to map the error
# back to its IR location. Canonical format:
#
#   "ir_extract.jl: <opcode> in @<funcname>:%<blockname>: <serialised instruction> — <reason>"
#
# This test asserts the format on a known-failing compilation (attempting
# to reversibly-compile a function that uses an unsupported floating-point
# intrinsic or similar). The test is narrow: it only checks the prefix and
# context fields; the trailing `<reason>` is free-form.

@testset "Bennett-cc0.6 standardized error format" begin
    # Pick an unsupported opcode: `urem` on two dynamic operands is supported,
    # but `frem` (Float64 remainder) routes through soft-float only if the
    # dispatch is registered. Easier: use an `fpext` Float32→Float64 (not in
    # the supported cast set — per README "missing opcodes" include fpext).
    #
    # Actually, a reliable "ir_extract unsupported" that exercises the
    # dispatcher fall-through is hard to construct without internal API
    # access. Instead, we test `_ir_error` directly on synthetic input.

    # The helper is file-private; reach it through the Bennett module.
    ir_error = getfield(Bennett, :_ir_error)

    # Build a synthetic LLVM instruction so we can invoke the formatter.
    using LLVM
    LLVM.Context() do _ctx
        mod = LLVM.Module("test_cc06")
        ft = LLVM.FunctionType(LLVM.Int32Type(), [LLVM.Int32Type()])
        fn = LLVM.Function(mod, "test_fn", ft)
        bb = LLVM.BasicBlock(fn, "entry")
        LLVM.IRBuilder() do builder
            LLVM.position!(builder, bb)
            arg = LLVM.parameters(fn)[1]
            ret = LLVM.ret!(builder, arg)

            # Call _ir_error on the ret instruction; should raise with the
            # canonical format.
            err = nothing
            try
                ir_error(ret, "test reason")
            catch e
                err = e
            end
            @test err isa ErrorException
            msg = sprint(showerror, err)
            @test occursin("ir_extract.jl:", msg)
            @test occursin("@test_fn", msg)
            @test occursin("%entry", msg)
            @test occursin("test reason", msg)
        end
        dispose(mod)
    end
end

@testset "Bennett-cc0.6 end-to-end error context on unsupported opcode" begin
    # Force the dispatcher fallthrough by handing the extractor an LLVM module
    # with an unsupported opcode. `va_arg` is not in our 38 supported opcodes
    # and is unlikely to ever be. Construct such a module directly, run it
    # through the same extract path, and check the error carries context.
    using LLVM
    LLVM.Context() do _ctx
        mod = LLVM.Module("test_cc06_e2e")
        i32 = LLVM.Int32Type()
        ft = LLVM.FunctionType(i32, [LLVM.PointerType()])
        fn = LLVM.Function(mod, "julia_cc06_probe_1", ft)
        bb = LLVM.BasicBlock(fn, "entry")

        LLVM.IRBuilder() do builder
            LLVM.position!(builder, bb)
            # Emit a `va_arg` via the raw C API (LLVM.jl has no high-level
            # builder for it). va_arg is dispatched by `_convert_instruction`'s
            # fall-through path, hitting the new canonical error.
            pname = "va_value"
            va = LLVM.API.LLVMBuildVAArg(
                builder.ref,
                LLVM.parameters(fn)[1].ref,
                i32.ref,
                pname)
            LLVM.API.LLVMBuildRet(builder.ref, va)
        end

        err = nothing
        try
            # Lower-level entry point (Bennett.extract_parsed_ir prefers a
            # Julia function). Walk the module directly via the same
            # _module_to_parsed_ir that user calls fan out to.
            getfield(Bennett, :_module_to_parsed_ir)(mod)
        catch e
            err = e
        end
        @test err isa ErrorException
        msg = sprint(showerror, err)
        @test occursin("ir_extract.jl:", msg)
        @test occursin("in @julia_cc06_probe_1", msg)
        @test occursin("%entry", msg)
        dispose(mod)
    end
end
