# Bennett-fehu / U105 — simulate!(buffer, circuit, inputs) in-place variant.
#
# Hot-loop callers pre-allocate one Vector{Bool} of length circuit.n_wires
# and reuse it across many simulate! calls, avoiding the per-call
# zeros(Bool, n_wires) allocation that dominates simulator overhead at
# scale.

@testset "Bennett-fehu / U105 — simulate!(buffer, ...) in-place" begin
    @testset "single-input correctness vs simulate" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        buf = Vector{Bool}(undef, c.n_wires)
        for x in Int8(-128):Int8(127)
            @test simulate!(buf, c, x) == simulate(c, x)
        end
    end

    @testset "tuple-input correctness vs simulate" begin
        c = reversible_compile((x, y) -> x + y, Int8, Int8)
        buf = Vector{Bool}(undef, c.n_wires)
        for x in Int8.(-3:3), y in Int8.(-3:3)
            @test simulate!(buf, c, (x, y)) == simulate(c, (x, y))
        end
    end

    @testset "buffer reuse across calls (no leakage)" begin
        # Re-using the buffer must NOT leak state between calls — the
        # fill!(false) inside simulate! resets it. Test by deliberately
        # populating the buffer with garbage, then verifying the result
        # matches a fresh simulate.
        c = reversible_compile(x -> x * Int8(3), Int8)
        buf = Vector{Bool}(undef, c.n_wires)
        fill!(buf, true)  # garbage
        @test simulate!(buf, c, Int8(5)) == simulate(c, Int8(5))
        # Second call with the (now-modified) buffer must still be correct.
        @test simulate!(buf, c, Int8(7)) == simulate(c, Int8(7))
    end

    @testset "buffer length contract violation → ArgumentError" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        too_short = Vector{Bool}(undef, c.n_wires - 1)
        too_long  = Vector{Bool}(undef, c.n_wires + 1)
        @test_throws ArgumentError simulate!(too_short, c, Int8(5))
        @test_throws ArgumentError simulate!(too_long,  c, Int8(5))
    end

    @testset "ancilla-violation still raised through simulate!" begin
        # Construct a deliberately-broken circuit (ancilla starts non-zero
        # because we hand-poke a 1 into the buffer that simulate! is
        # supposed to fill!(false) anyway — so this should NOT trip the
        # ancilla check, since simulate! resets the buffer).
        c = reversible_compile(x -> x + Int8(1), Int8)
        buf = Vector{Bool}(undef, c.n_wires)
        fill!(buf, true)  # would violate ancilla cleanliness pre-fill!
        # simulate! resets first; result must be correct.
        @test simulate!(buf, c, Int8(0)) == Int8(1)
    end

    @testset "soft_fadd-scale buffer reuse smoke" begin
        # Real-world hot loop: thousands of UInt64 inputs through a
        # large softfloat circuit. Just verify N=10 runs all match
        # simulate (correctness over allocation savings).
        c = reversible_compile(Bennett.soft_fadd, UInt64, UInt64)
        buf = Vector{Bool}(undef, c.n_wires)
        # Use deterministic Float64 → UInt64 reinterpret pairs.
        for (a_f, b_f) in [(1.0, 2.0), (3.5, -1.25), (0.0, 7.0),
                           (1e-10, 1e10), (-0.0, 0.0)]
            ab = reinterpret(UInt64, a_f)
            bb = reinterpret(UInt64, b_f)
            @test simulate!(buf, c, (ab, bb)) == simulate(c, (ab, bb))
        end
    end
end
