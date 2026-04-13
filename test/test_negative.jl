using Test
using Bennett

@testset "Negative tests (error conditions)" begin
    @testset "Loop without max_loop_iterations" begin
        # A data-dependent loop that LLVM cannot unroll (genuinely unbounded —
        # the exit condition depends on computed value, with no step counter).
        # Needs max_loop_iterations or else extraction detects a back-edge
        # and lowering errors out.
        #
        # Previous fixture used `steps < Int8(5)` as an auxiliary bound, which
        # modern LLVM aggressively unrolls — the bounded loop now compiles
        # cleanly without errors. Removed the counter so the exit is purely
        # data-dependent (Bennett-s4b4).
        function collatz_step(x::Int8)
            n = x
            while n > Int8(1)
                n = ifelse(n & Int8(1) == Int8(0), n >> Int8(1), Int8(3) * n + Int8(1))
            end
            return n
        end
        @test_throws Exception reversible_compile(collatz_step, Int8)
    end

    @testset "Float64 with too many arguments" begin
        f4(a, b, c, d) = a + b + c + d
        @test_throws ErrorException reversible_compile(f4, Float64, Float64, Float64, Float64)
    end

    @testset "Single-input simulate with multi-input circuit" begin
        m(x::Int8, y::Int8) = x + y
        c = reversible_compile(m, Int8, Int8)
        @test_throws ErrorException simulate(c, Int8(1))
    end
end
