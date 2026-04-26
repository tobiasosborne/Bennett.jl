# Bennett-lgzx / U114: `_convert_instruction` no longer silently drops
# unsupported stores.
#
# Pre-fix two `return nothing` paths in the store handler at
# src/ir_extract.jl swallowed: (a) stores of non-integer values
# (e.g. raw Float64 stores not rerouted by SoftFloat dispatch) and
# (b) stores whose target pointer was not a registered SSA name. Both
# made downstream lowering produce a circuit with the store missing,
# silently corrupting the result.
#
# Per CLAUDE.md §1 these now `_ir_error` with the offending instruction
# and a Bennett-lgzx tag.

using Test
using Bennett
using LLVM

@testset "Bennett-lgzx / U114: store extraction fails loud" begin

    @testset "T1: float store errors with Bennett-lgzx tag" begin
        # Function returns i32 (not void) so the extractor doesn't fail on
        # the return-type width query before reaching the store check.
        ir = """
        define i32 @julia_lgzx_float_store(double %x, ptr %p) {
        top:
          store double %x, ptr %p
          ret i32 0
        }
        """
        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, ir)
            try
                Bennett._module_to_parsed_ir(mod)
                @test false  # should not reach here
            catch e
                msg = sprint(showerror, e)
                @test occursin("Bennett-lgzx", msg)
                @test occursin("non-integer", msg)
            finally
                dispose(mod)
            end
        end
    end

    @testset "T2: integer store still extracts correctly (regression)" begin
        # Exact same shape as test_store_alloca_extract.jl T1a.2 — must
        # remain green after lgzx. Uses a 32-bit integer store + load.
        ir = """
        define i32 @julia_lgzx_int_store(i32 %"x::Int32") {
        top:
          %p = alloca i32
          store i32 %"x::Int32", ptr %p
          %v = load i32, ptr %p
          ret i32 %v
        }
        """
        local n_store = 0
        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, ir)
            parsed = Bennett._module_to_parsed_ir(mod)
            for inst in parsed.blocks[1].instructions
                inst isa Bennett.IRStore && (n_store += 1)
            end
            dispose(mod)
        end
        @test n_store == 1
    end

    @testset "T3: integer store via i8 width also still extracts" begin
        ir = """
        define i8 @julia_lgzx_i8_store(i8 %"x::Int8") {
        top:
          %p = alloca i8
          store i8 %"x::Int8", ptr %p
          %v = load i8, ptr %p
          ret i8 %v
        }
        """
        local n_store = 0
        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, ir)
            parsed = Bennett._module_to_parsed_ir(mod)
            for inst in parsed.blocks[1].instructions
                inst isa Bennett.IRStore && (n_store += 1)
            end
            dispose(mod)
        end
        @test n_store == 1
    end
end
