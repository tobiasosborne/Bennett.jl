@testset "Ancilla reuse (eager cleanup baseline)" begin

    # Compare ancilla count for a chain of operations.
    # With full Bennett, each intermediate value is kept live.
    # With wire reuse, freed wires should be recycled.

    @testset "simple chain — ancilla count" begin
        # f(x) = ((x+1)+2)+3 — 3 intermediate additions
        f(x::Int8) = ((x + Int8(1)) + Int8(2)) + Int8(3)
        c = reversible_compile(f, Int8)

        # Just verify correctness for now — optimization comes later
        for x in typemin(Int8):typemax(Int8)
            @test Int8(simulate(c, x)) == f(x)
        end
        @test verify_reversibility(c)

        # Bennett-kv7b / U65 (#03 F12): pin ancilla count rather than just
        # printing it. Pre-fix the println alone was a 0-assertion path —
        # ancilla regressions silently passed.
        @test ancilla_count(c) == 25
    end

    @testset "polynomial — ancilla count" begin
        g(x::Int8) = x * x + Int8(3) * x + Int8(1)
        c = reversible_compile(g, Int8)
        for x in typemin(Int8):typemax(Int8)
            @test Int8(simulate(c, x)) == g(x)
        end
        @test verify_reversibility(c)
        # Bennett-kv7b / U65 (#03 F12): pin polynomial ancilla baseline.
        @test ancilla_count(c) == 249
    end
end
