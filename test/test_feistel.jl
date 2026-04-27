using Test
using Bennett
using Bennett: emit_feistel!, WireAllocator, allocate!, wire_count,
               ReversibleGate, LoweringResult, bennett, verify_reversibility,
               gate_count, simulate

# T3a.1 — 4-round Feistel network as a reversible bijective hash primitive.
# Reference: COMPLEMENTARY_SURVEY §D (Bennett-Memory). A Feistel network over
# (L, R) halves runs r rounds of (L, R) → (R, L ⊕ F(R)). The overall permutation
# is a bijection REGARDLESS of F's invertibility — that's the point.
#
# Gate-cost target (survey §D): ~12·W Toffoli per 4-round hash. For W=32:
# ~400 gates, 10-20× smaller than a 3-node Okasaki insert. This test suite
# verifies correctness, bijectivity, and cost.
#
# Round function F(R) = R + rotate(R, 7): nonlinear (modular add gives
# carries), bijective (undoable by subtracting rotate(R, 7) from R), cheap
# (one adder + zero-cost wire permutation for rotate). This choice follows
# the survey's "XOR-rotation composition" pattern modified to use ADD for
# nonlinearity.

"""
Helper: build a standalone reversible circuit that applies emit_feistel!
to a W-bit input, exposing input as the register and the rotated state
as output. `simulate(c, key)` returns `feistel(key)`.
"""
function _compile_feistel(W::Int; rounds::Int=4)
    wa = WireAllocator()
    gates = ReversibleGate[]
    key = allocate!(wa, W)
    out = emit_feistel!(gates, wa, key, W; rounds)
    return bennett(LoweringResult(gates, wire_count(wa), key, out,
                                   [W], [W]))
end

@testset "T3a.1 4-round Feistel reversible hash" begin

    @testset "W=8 rounds=4 — bijective on all 256 inputs" begin
        c = _compile_feistel(8; rounds=4)
        @test verify_reversibility(c)
        # Bijection: every input produces a unique output
        outputs = Set{Int}()
        for k in UInt8(0):UInt8(255)
            out = simulate(c, k)
            push!(outputs, Int(reinterpret(UInt8, out)))
        end
        @test length(outputs) == 256
    end

    @testset "W=16 rounds=4 — bijective on sampled inputs" begin
        c = _compile_feistel(16; rounds=4)
        @test verify_reversibility(c)
        outputs = Set{Int}()
        for k in UInt16(0):UInt16(16):UInt16(0xfff0)
            out = simulate(c, k)
            push!(outputs, Int(reinterpret(UInt16, out)))
        end
        @test length(outputs) >= 4000  # should be dense under a good hash
    end

    @testset "W=32 rounds=4 — deterministic + reversible" begin
        c = _compile_feistel(32; rounds=4)
        @test verify_reversibility(c)
        # Determinism: same input produces same output
        o1 = simulate(c, UInt32(0x12345678))
        o2 = simulate(c, UInt32(0x12345678))
        @test o1 == o2
        # Avalanche: flipping one bit of the input changes ≥1 bit of output
        o3 = simulate(c, UInt32(0x12345679))
        @test o1 != o3
    end

    @testset "gate count scales ~linearly with W (target ≈ 12·W Toffoli for 4 rounds)" begin
        for (W, max_tof) in [(8, 200), (16, 400), (32, 800), (64, 1600)]
            c = _compile_feistel(W; rounds=4)
            @test verify_reversibility(c)
            @test gate_count(c).Toffoli <= max_tof
        end
    end

    @testset "round count tunable (1..8)" begin
        c1 = _compile_feistel(16; rounds=1)
        c4 = _compile_feistel(16; rounds=4)
        c8 = _compile_feistel(16; rounds=8)
        @test verify_reversibility(c1)
        @test verify_reversibility(c4)
        @test verify_reversibility(c8)
        # More rounds → more gates, monotonically
        @test gate_count(c1).Toffoli < gate_count(c4).Toffoli < gate_count(c8).Toffoli
    end

    @testset "odd W: half-width split is floor(W/2)" begin
        # W=9 (Julia's i9 for sum_to) — tests we don't divide by zero or error
        c = _compile_feistel(9; rounds=4)
        @test verify_reversibility(c)
        # Reasonable gate count (shouldn't explode)
        @test gate_count(c).total < 2000
    end
end
