using Test
using Bennett
using LLVM

# Hand-crafted LLVM IR is used deliberately: the existing insertvalue handler
# crashes on complex Julia runtime IR (unrelated pre-existing issue). Using
# minimal hand-authored IR lets us test extraction in isolation.

@testset "T1a.2 store/alloca extraction" begin

    @testset "alloca + store + load extracts correctly" begin
        ir = """
        define i8 @julia_f_1(i8 %"x::Int8") {
        top:
          %p = alloca i8
          store i8 %"x::Int8", ptr %p
          %v = load i8, ptr %p
          ret i8 %v
        }
        """
        local n_alloca = 0
        local n_store = 0
        local n_load = 0
        local alloca_inst::Union{Nothing,Bennett.IRAlloca} = nothing
        local store_inst::Union{Nothing,Bennett.IRStore} = nothing

        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, ir)
            parsed = Bennett._module_to_parsed_ir(mod)
            @test length(parsed.blocks) == 1
            for inst in parsed.blocks[1].instructions
                if inst isa Bennett.IRAlloca
                    n_alloca += 1
                    alloca_inst = inst
                elseif inst isa Bennett.IRStore
                    n_store += 1
                    store_inst = inst
                elseif inst isa Bennett.IRLoad
                    n_load += 1
                end
            end
            dispose(mod)
        end

        @test n_alloca == 1
        @test n_store == 1
        @test n_load == 1

        # Alloca fields: dest=:p, elem_width=8, n_elems=iconst(1)
        @test alloca_inst !== nothing
        @test alloca_inst.dest == :p
        @test alloca_inst.elem_width == 8
        @test alloca_inst.n_elems isa Bennett.ConstOperand
        @test alloca_inst.n_elems.value == 1

        # Store fields: ptr=ssa(:p), val=ssa(x::Int8), width=8
        @test store_inst !== nothing
        @test store_inst.ptr isa Bennett.SSAOperand
        @test store_inst.ptr.name == :p
        @test store_inst.val isa Bennett.SSAOperand
        @test store_inst.val.name == Symbol("x::Int8")
        @test store_inst.width == 8
    end

    @testset "alloca with explicit array count" begin
        ir = """
        define i8 @julia_f_1(i8 %"x::Int8") {
        top:
          %p = alloca i8, i32 4
          ret i8 %"x::Int8"
        }
        """
        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, ir)
            parsed = Bennett._module_to_parsed_ir(mod)
            insts = parsed.blocks[1].instructions
            allocas = filter(i -> i isa Bennett.IRAlloca, insts)
            @test length(allocas) == 1
            @test allocas[1].n_elems isa Bennett.ConstOperand
            @test allocas[1].n_elems.value == 4
            dispose(mod)
        end
    end

    @testset "store of constant" begin
        ir = """
        define i8 @julia_f_1(i8 %"x::Int8") {
        top:
          %p = alloca i8
          store i8 7, ptr %p
          ret i8 0
        }
        """
        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, ir)
            parsed = Bennett._module_to_parsed_ir(mod)
            stores = filter(i -> i isa Bennett.IRStore, parsed.blocks[1].instructions)
            @test length(stores) == 1
            @test stores[1].val isa Bennett.ConstOperand
            @test stores[1].val.value == 7
            dispose(mod)
        end
    end

    @testset "float alloca is skipped (matches IRLoad non-integer policy)" begin
        # SoftFloat dispatch maps Float64 to UInt64 before IR extraction, so
        # float allocas are rare. For now we skip them (same as non-integer
        # loads at ir_extract.jl:751).
        ir = """
        define i8 @julia_f_1(i8 %"x::Int8") {
        top:
          %p = alloca float
          ret i8 %"x::Int8"
        }
        """
        LLVM.Context() do _ctx
            mod = parse(LLVM.Module, ir)
            parsed = Bennett._module_to_parsed_ir(mod)
            allocas = filter(i -> i isa Bennett.IRAlloca, parsed.blocks[1].instructions)
            @test isempty(allocas)
            dispose(mod)
        end
    end

    @testset "backward compat: standard optimized compile unaffected" begin
        c = reversible_compile(x -> x + Int8(3), Int8)
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == x + Int8(3)
        end
        @test verify_reversibility(c)
    end
end
