using Test
using Bennett

# T5-P5b — extract_parsed_ir_from_bc(path; entry_function=...)
#
# Uses the same hand-written fixture as P5a, compiled to bitcode via
# llvm-as. If llvm-as is unavailable the testset is skipped.

const P5B_LL_FIXTURE = joinpath(@__DIR__, "fixtures", "ll", "p5a_add3.ll")

const LLVM_AS = strip(read(
    `bash -lc "which llvm-as 2>/dev/null || which llvm-as-18 2>/dev/null || true"`,
    String))

have_llvm_as = !isempty(LLVM_AS) && isfile(LLVM_AS)

@testset "Bennett-T5-P5b extract_parsed_ir_from_bc" begin
    if !have_llvm_as
        @info "Skipping P5b bitcode test: llvm-as not found"
        @test_skip "llvm-as not available"
    else
        bc_path = tempname() * ".bc"
        try
            run(`$LLVM_AS -o $bc_path $P5B_LL_FIXTURE`)
            @test isfile(bc_path)

            parsed = Bennett.extract_parsed_ir_from_bc(bc_path;
                                                       entry_function="foo")
            @test parsed isa Bennett.ParsedIR
            @test length(parsed.args) == 1
            @test parsed.args[1][2] == 8
            @test parsed.ret_width == 8

            c = reversible_compile(parsed)
            for x in typemin(Int8):typemax(Int8)
                @test simulate(c, Int8(x)) == (x + Int8(3)) % Int8
            end
            @test verify_reversibility(c; n_tests=3)
        finally
            rm(bc_path; force=true)
        end
    end
end
