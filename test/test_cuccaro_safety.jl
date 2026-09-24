using Test
using Bennett

# Cuccaro in-place adder safety — end-to-end under an EXPLICIT `add=:cuccaro`.
#
# Bennett-stwr: this file used to compile with the default `add=:auto`
# (which has resolved to `:ripple` since Bennett-spa8 / U27), so it never
# exercised Cuccaro at all while its names claimed to. Every testset now
# passes `add=:cuccaro` (both `optimize=true` and `optimize=false`, whose IR
# shapes differ — e.g. LLVM folds `x + x` to `shl`) and asserts, on every
# input, that operands which are read more than once are NOT overwritten.
# The mechanism (exclusive-reader eligibility, op1 swap, copy-in) is pinned
# in test_stwr_cuccaro_soundness.jl.

@testset "Cuccaro in-place adder safety (add=:cuccaro)" begin
    for opt in (true, false)
        @testset "optimize=$opt" begin
            @testset "x + x: op1 === op2 must never alias the adder registers" begin
                f_double(x::Int8) = x + x
                c = reversible_compile(f_double, Int8; add=:cuccaro, optimize=opt)
                for x in typemin(Int8):typemax(Int8)
                    @test simulate(c, x) == f_double(x)
                end
                @test verify_reversibility(c)
            end

            @testset "(x+1) + (x+2): dead intermediates may be consumed in place" begin
                g(x::Int8) = (x + Int8(1)) + (x + Int8(2))
                c = reversible_compile(g, Int8; add=:cuccaro, optimize=opt)
                for x in typemin(Int8):typemax(Int8)
                    @test simulate(c, x) == g(x)
                end
                @test verify_reversibility(c)
            end

            @testset "x + x + x: multi-use operand never overwritten" begin
                h(x::Int8) = x + x + x
                c = reversible_compile(h, Int8; add=:cuccaro, optimize=opt)
                for x in typemin(Int8):typemax(Int8)
                    @test simulate(c, x) == h(x)
                end
                @test verify_reversibility(c)
            end

            @testset "x + y + x: x read twice, full Int8 × Int8" begin
                m(x::Int8, y::Int8) = x + y + x
                c = reversible_compile(m, Int8, Int8; add=:cuccaro, optimize=opt)
                for x in typemin(Int8):typemax(Int8), y in typemin(Int8):typemax(Int8)
                    @test simulate(c, (x, y)) == m(x, y)
                end
                @test verify_reversibility(c)
            end
        end
    end
end
