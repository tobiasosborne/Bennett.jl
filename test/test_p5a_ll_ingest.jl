using Test
using Bennett

# T5-P5a — extract_parsed_ir_from_ll(path; entry_function=...)
#
# Hand-written .ll fixture exercises the new entry point on a minimal
# non-Julia-shaped module (no `julia_*` prefix; plain `@foo`).

const P5A_LL_FIXTURE = joinpath(@__DIR__, "fixtures", "ll", "p5a_add3.ll")

@testset "Bennett-T5-P5a extract_parsed_ir_from_ll" begin
    parsed = Bennett.extract_parsed_ir_from_ll(P5A_LL_FIXTURE;
                                                entry_function="foo")
    @test parsed isa Bennett.ParsedIR

    # Structural: one i8 arg, i8 return, one block, one add + one ret.
    @test length(parsed.args) == 1
    @test parsed.args[1][2] == 8
    @test parsed.ret_width == 8

    c = reversible_compile(parsed)
    @test c isa Bennett.ReversibleCircuit
    for x in typemin(Int8):typemax(Int8)
        @test simulate(c, Int8(x)) == (x + Int8(3)) % Int8
    end
    @test verify_reversibility(c; n_tests=3)
end
