using Test
using Bennett
using Bennett: register_callee!, extract_parsed_ir, extract_parsed_ir_set_from_julia,
               IRCall, _lookup_callee, _demangle_llvm_callee, _demangle_callee_symbol

# Bennett-wh1p — callee symbol handling folded case. `register_callee!` keys the
# registry by `string(nameof(f))` (case-sensitive), but `_lookup_callee`
# lowercased the demangled LLVM name before the lookup, and the closed-world
# check's `_demangle_callee_symbol` lowercased its capture too. Two failure modes:
#   * SILENT: `Wh1pBump` and `wh1pbump` both registered → `j_Wh1pBump_NNN`
#     resolved to `wh1pbump`, whose body was inlined for both calls. 256/256
#     Int8 outputs wrong, `verify_reversibility` still passed.
#   * LOUD: a capitalised callee with no lowercase namesake never resolved, so
#     `extract_parsed_ir_set_from_julia` rejected a valid program.

@noinline Wh1pBump(x::Int8) = x + Int8(1)
@noinline wh1pbump(x::Int8) = x + Int8(100)
wh1p_both(x::Int8) = Wh1pBump(x) + wh1pbump(x)

@noinline Wh1pUpper(x::Int8) = x * Int8(3)
wh1p_upper_root(x::Int8) = Wh1pUpper(x) + Int8(7)

@noinline Wh1pSetUpper(x::Int64) = x + 1
wh1p_set_root(x::Int64) = Wh1pSetUpper(x)

register_callee!(Wh1pBump)
register_callee!(wh1pbump)
register_callee!(Wh1pUpper)

_wh1p_calls(pir) = [i.callee for b in pir.blocks for i in b.instructions if i isa IRCall]

@testset "Bennett-wh1p: case-preserving callee resolution" begin
    @testset "shared demangler keeps the name's case" begin
        @test _demangle_llvm_callee("j_Wh1pBump_101") == "Wh1pBump"
        @test _demangle_llvm_callee("julia_Foo_7") == "Foo"
        @test _demangle_llvm_callee("j_foo_7") == "foo"
        @test _demangle_llvm_callee("JULIA_Foo_7") == "Foo"   # prefix only is case-insensitive
        @test _demangle_llvm_callee("soft_fcmp_ole") === nothing
        @test _demangle_llvm_callee("julia_Foo") === nothing
        @test _demangle_callee_symbol(Symbol("j_#MakeIt##0_12")) === Symbol("#MakeIt##0")
        @test _demangle_callee_symbol(:llvm_trap) === nothing
    end

    @testset "_lookup_callee binds case-distinct names to their own bodies" begin
        @test _lookup_callee("j_Wh1pBump_101") === Wh1pBump
        @test _lookup_callee("j_wh1pbump_102") === wh1pbump
        @test _lookup_callee("julia_Wh1pUpper_5") === Wh1pUpper
        @test _lookup_callee("j_WH1PBUMP_9") === nothing      # no folding onto either
    end

    @testset "silent witness: Wh1pBump vs wh1pbump, all 256 Int8 inputs" begin
        pir = extract_parsed_ir(wh1p_both, Tuple{Int8})
        calls = _wh1p_calls(pir)
        @test Wh1pBump in calls
        @test wh1pbump in calls
        c = reversible_compile(wh1p_both, Int8)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == wh1p_both(x)
        end
        @test verify_reversibility(c)
    end

    @testset "capitalised callee with no lowercase namesake, all 256 Int8 inputs" begin
        @test Wh1pUpper in _wh1p_calls(extract_parsed_ir(wh1p_upper_root, Tuple{Int8}))
        c = reversible_compile(wh1p_upper_root, Int8)
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == wh1p_upper_root(x)
        end
        @test verify_reversibility(c)
    end

    @testset "closed-world set extraction with a capitalised helper" begin
        ss = extract_parsed_ir_set_from_julia(wh1p_set_root, Tuple{Int64})
        keys_ = String.(first.(ss))
        @test any(startswith("Wh1pSetUpper#"), keys_)
        root = last(ss[findfirst(startswith("wh1p_set_root#"), keys_)])
        @test _wh1p_calls(root) == [Wh1pSetUpper]
    end
end
