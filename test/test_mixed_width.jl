using Test
using Bennett

# Bennett-8gkj: every compile here must succeed and match native Julia on all
# 256 Int8 inputs. There is deliberately no try/catch: a compiler exception is
# a regression and must turn this file red (it used to be converted into a
# `@test_broken false`, which kept the file green for any error at all).
@testset "Mixed-width (sext/zext/trunc)" begin
    @testset "sum_to (uses zext i9, trunc, multi-block)" begin
        # LLVM computes closed-form n*(n+1)/2 using i9 arithmetic
        function sum_to(n::Int8)
            acc = Int8(0)
            for i in Int8(1):n
                acc += i
            end
            return acc
        end

        circuit = reversible_compile(sum_to, Int8)
        bad = [n for n in typemin(Int8):typemax(Int8) if simulate(circuit, n) != sum_to(n)]
        isempty(bad) || @info "sum_to mismatches" first(bad, 5)
        @test isempty(bad)
        @test verify_reversibility(circuit)
        println("  sum_to (closed form): ", gate_count(circuit))
    end

    @testset "Explicit sext + mul + trunc" begin
        # Widen to Int16, multiply, truncate back. `Int8(::Int16)` is a checked
        # conversion (an InexactError branch in the IR), but the value is always
        # in [-64, 63], so the throw path is unreachable for every input.
        function widen_mul(x::Int8)
            w = Int16(x)  # sext i8 to i16
            return Int8(w * w % Int16(128) - Int16(64))  # keep in Int8 range
        end

        circuit = reversible_compile(widen_mul, Int8)
        bad = [x for x in typemin(Int8):typemax(Int8) if simulate(circuit, x) != widen_mul(x)]
        isempty(bad) || @info "widen_mul mismatches" first(bad, 5)
        @test isempty(bad)
        @test verify_reversibility(circuit)
        println("  widen_mul: ", gate_count(circuit))
    end
end
