using Test
using Bennett
using Bennett: emit_shadow_store!, emit_shadow_load!,
               WireAllocator, allocate!, wire_count,
               ReversibleGate, NOTGate, CNOTGate,
               LoweringResult, bennett, verify_reversibility,
               gate_count, simulate

# T3b.2 — Shadow memory primitives. Protocol per docs/memory/shadow_design.md:
# emit_shadow_store!(primal, tape_slot, val)  — primal ← val, tape_slot ← old primal
# emit_shadow_load!(primal)                   — returns CNOT-copy of primal
#
# Correctness invariant: after a full Bennett construction around any
# sequence of store/load ops, the output wires hold the correct final
# primal contents AND all shadow tape + primal wires return to zero.

@testset "T3b.2 shadow memory primitives" begin

    @testset "single store + load round-trip (W=8)" begin
        # Circuit: primal starts at 0. Store x to primal. Load primal → should equal x.
        wa = WireAllocator(); gates = ReversibleGate[]
        W = 8
        x = allocate!(wa, W)  # input value
        primal = allocate!(wa, W)  # zero-initialized "memory"
        tape = allocate!(wa, W)    # shadow tape slot

        emit_shadow_store!(gates, wa, primal, tape, x, W)
        out = emit_shadow_load!(gates, wa, primal, W)

        c = bennett(LoweringResult(gates, wire_count(wa), x, out,
                                    [W], [W]))
        @test verify_reversibility(c)
        for xv in UInt8(0):UInt8(255)
            # Bennett-zc50 / U100: simulate preserves UInt8-in → UInt8-out.
            @test simulate(c, xv) == xv
        end
    end

    @testset "two stores — last write wins" begin
        # Store x, then store y to same primal. Load should give y.
        wa = WireAllocator(); gates = ReversibleGate[]
        W = 8
        x = allocate!(wa, W)
        y = allocate!(wa, W)
        primal = allocate!(wa, W)
        tape1 = allocate!(wa, W)
        tape2 = allocate!(wa, W)

        emit_shadow_store!(gates, wa, primal, tape1, x, W)
        emit_shadow_store!(gates, wa, primal, tape2, y, W)
        out = emit_shadow_load!(gates, wa, primal, W)

        c = bennett(LoweringResult(gates, wire_count(wa), vcat(x, y), out,
                                    [W, W], [W]))
        @test verify_reversibility(c)
        for xv in UInt8(0):UInt8(15), yv in UInt8(0):UInt8(15)
            @test simulate(c, (xv, yv)) == yv
        end
    end

    @testset "load after store recovers stored value" begin
        # Store x, load v1, store y, load v2. v1==x, v2==y.
        wa = WireAllocator(); gates = ReversibleGate[]
        W = 8
        x = allocate!(wa, W)
        y = allocate!(wa, W)
        primal = allocate!(wa, W)
        tape1 = allocate!(wa, W)
        tape2 = allocate!(wa, W)

        emit_shadow_store!(gates, wa, primal, tape1, x, W)
        v1 = emit_shadow_load!(gates, wa, primal, W)
        emit_shadow_store!(gates, wa, primal, tape2, y, W)
        v2 = emit_shadow_load!(gates, wa, primal, W)

        # Output is (v1 || v2) — concatenated; test exercise checks each
        out = vcat(v1, v2)
        c = bennett(LoweringResult(gates, wire_count(wa), vcat(x, y), out,
                                    [W, W], [W, W]))
        @test verify_reversibility(c)
        for xv in UInt8(0):UInt8(3), yv in UInt8(0):UInt8(3)
            got = simulate(c, (xv, yv))
            @test got == (xv, yv)
        end
    end

    @testset "gate count per store is 3W CNOT" begin
        # Exactly 3W CNOTs per store per shadow-design.md §4.2
        for W in (4, 8, 16)
            wa = WireAllocator(); gates = ReversibleGate[]
            val = allocate!(wa, W)
            primal = allocate!(wa, W)
            tape = allocate!(wa, W)
            emit_shadow_store!(gates, wa, primal, tape, val, W)
            cnots = count(g -> g isa CNOTGate, gates)
            @test cnots == 3 * W
            # Zero Toffolis in a single store
            @test count(g -> g isa Bennett.ToffoliGate, gates) == 0
        end
    end

    @testset "gate count per load is W CNOT" begin
        for W in (4, 8, 16)
            wa = WireAllocator(); gates = ReversibleGate[]
            primal = allocate!(wa, W)
            out = emit_shadow_load!(gates, wa, primal, W)
            @test length(out) == W
            cnots = count(g -> g isa CNOTGate, gates)
            @test cnots == W
        end
    end

    @testset "five stores + one load on W=16" begin
        # Stress: 5 writes, final read. Last write wins.
        wa = WireAllocator(); gates = ReversibleGate[]
        W = 16
        vals = [allocate!(wa, W) for _ in 1:5]
        primal = allocate!(wa, W)
        tapes = [allocate!(wa, W) for _ in 1:5]

        for k in 1:5
            emit_shadow_store!(gates, wa, primal, tapes[k], vals[k], W)
        end
        out = emit_shadow_load!(gates, wa, primal, W)

        c = bennett(LoweringResult(gates, wire_count(wa),
                                    vcat(vals...), out,
                                    fill(W, 5), [W]))
        @test verify_reversibility(c)
        # Sample inputs (exhaustive 16^5 is infeasible)
        for _ in 1:50
            vs = Tuple(rand(UInt16) for _ in 1:5)
            @test simulate(c, vs) == vs[5]
        end
    end
end
