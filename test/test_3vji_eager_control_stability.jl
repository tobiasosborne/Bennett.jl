# Bennett-3vji (Astra F9): gate-level EagerStrategy replayed a dead-end
# wire's whole modification path right after its last write. Replaying a
# gate only undoes it if its controls still hold the values they had when
# the gate first ran; a control rewritten in between (e.g. a NOT on the
# control wire) left the dead-end ancilla dirty. The oracle is
# DefaultStrategy: same outputs on every input, inputs preserved, all
# ancillae zero.
using Test
using Bennett
using Bennett: bennett, LoweringResult, NOTGate, CNOTGate, ToffoliGate,
               EagerStrategy
using Random

const _G3 = Bennett.ReversibleGate

# Same output as DefaultStrategy on every input, and a clean circuit.
function _eager_matches_default(lr, inputs)
    c_def = bennett(lr)
    c_eag = bennett(lr; strategy=EagerStrategy())
    for x in inputs
        simulate(c_eag, x) == simulate(c_def, x) || return false
    end
    return verify_reversibility(c_eag)
end

@testset "Bennett-3vji: Eager dead-end cleanup needs stable controls" begin

    @testset "three-gate fixture: NOT on the control between two writes" begin
        lr = LoweringResult(_G3[CNOTGate(1, 3), NOTGate(1), CNOTGate(1, 3)],
                            3, [1], [2], [1], [1])
        c = bennett(lr; strategy=EagerStrategy())
        for x in 0:1
            @test simulate(c, x) == simulate(bennett(lr), x) == 0
        end
        @test verify_reversibility(c)
    end

    @testset "early cleanup still fires when controls are stable" begin
        # Wire 3 is a dead end written only by gate 2, whose control (wire 1)
        # is never rewritten, so Eager replays gate 2 immediately.
        lr = LoweringResult(_G3[CNOTGate(1, 2), CNOTGate(1, 3)],
                            3, [1], [2], [1], [1])
        c = bennett(lr; strategy=EagerStrategy())
        @test c.gates[3] == CNOTGate(1, 3)
        for x in 0:1
            @test simulate(c, x) == x
        end
        @test verify_reversibility(c)
    end

    @testset "production witness: (x+3)*(x+1), add=:qcla, all Int8" begin
        f(x::Int8) = (x + Int8(3)) * (x + Int8(1))
        lr = Bennett.lower(extract_parsed_ir(f, Tuple{Int8}; optimize=false);
                           add=:qcla, fold_constants=false)
        c = bennett(lr; strategy=EagerStrategy())
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == f(x)
        end
        @test verify_reversibility(c)
    end

    @testset "random gate sequences with interleaved control writes" begin
        rng = MersenneTwister(0x3b1)
        n_wires = 7
        n_bad = 0
        for trial in 1:300
            gates = _G3[]
            for _ in 1:rand(rng, 1:14)
                k = rand(rng, 1:3)
                ws = randperm(rng, n_wires)
                g = k == 1 ? NOTGate(ws[1]) :
                    k == 2 ? CNOTGate(ws[1], ws[2]) :
                             ToffoliGate(ws[1], ws[2], ws[3])
                push!(gates, g)
            end
            # inputs 1:2 (2 bits), output wire 3, ancillae 4:7
            lr = LoweringResult(gates, n_wires, [1, 2], [3], [2], [1])
            ok = try _eager_matches_default(lr, 0:3) catch; false end
            n_bad += !ok
        end
        @test n_bad == 0
    end
end
