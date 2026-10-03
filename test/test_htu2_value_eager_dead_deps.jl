# Bennett-htu2 (Astra F10): ValueEagerStrategy uncomputed a dead-end group
# during the forward pass but never released the consumer counts it held on
# its dependency groups, so Phase 3 never scheduled those dependencies and
# their wires stayed dirty. The oracle is DefaultStrategy: same outputs on
# every input, inputs preserved, all ancillae zero.
using Test
using Bennett
using Bennett: bennett, LoweringResult, GateGroup, NOTGate, CNOTGate,
               ToffoliGate, ValueEagerStrategy
using Random

const _GH = Bennett.ReversibleGate

# Same output as DefaultStrategy on every input, and a clean circuit.
function _value_eager_matches_default(lr, inputs)
    c_def = bennett(lr)
    c_ve = bennett(lr; strategy=ValueEagerStrategy())
    for x in inputs
        simulate(c_ve, x) == simulate(c_def, x) || return false
    end
    return verify_reversibility(c_ve)
end

# Random straight-line SSA-shaped LoweringResult: inputs on wires 1:2, each
# group writes only its own fresh wires, reading inputs, the result wires of
# the groups it names in `input_ssa_vars`, and its own other wires.
function _random_grouped_lr(rng)
    n_groups = rand(rng, 1:6)
    gates = _GH[]
    groups = GateGroup[]
    next_wire = 3
    for k in 1:n_groups
        rw = collect(next_wire:next_wire + rand(rng, 1:2) - 1)
        next_wire += length(rw)
        deps = k == 1 ? Int[] : unique(rand(rng, 1:k-1, rand(rng, 0:2)))
        pool = vcat([1, 2], (groups[d].result_wires for d in deps)...)
        gs = length(gates) + 1
        for _ in 1:rand(rng, 1:4)
            t = rand(rng, rw)
            ctrls = shuffle(rng, setdiff(vcat(pool, rw), [t]))
            kind = rand(rng, 1:3)
            g = kind == 1 || isempty(ctrls) ? NOTGate(t) :
                kind == 2 || length(ctrls) < 2 ? CNOTGate(ctrls[1], t) :
                                                 ToffoliGate(ctrls[1], ctrls[2], t)
            push!(gates, g)
        end
        ivars = vcat([:x], [groups[d].ssa_name for d in deps])
        push!(groups, GateGroup(Symbol(:g, k), gs, length(gates), rw, ivars,
                                first(rw), last(rw)))
    end
    outs = unique(vcat((groups[k].result_wires for k in 1:n_groups
                        if rand(rng) < 0.35)...))
    isempty(outs) && (outs = [1])   # output an input wire: every group is dead
    return LoweringResult(gates, next_wire - 1, [1, 2], outs, [2],
                          [length(outs)], groups, false)
end

@testset "Bennett-htu2: ValueEager dead groups release their dependencies" begin

    @testset "Astra F10 witness: dead b reads a" begin
        gates = _GH[CNOTGate(1, 2), CNOTGate(2, 3)]
        groups = [GateGroup(:a, 1, 1, [2], Symbol[], 2, 2),
                  GateGroup(:b, 2, 2, [3], [:a], 3, 3)]
        lr = LoweringResult(gates, 3, [1], [1], [1], [1], groups, false)
        c = bennett(lr; strategy=ValueEagerStrategy())
        for x in 0:1
            @test simulate(c, x) == simulate(bennett(lr), x) == x
        end
        @test verify_reversibility(c)
    end

    @testset "chain of dead groups: c reads b reads a, output is a" begin
        gates = _GH[CNOTGate(1, 2), CNOTGate(2, 3), CNOTGate(3, 4)]
        groups = [GateGroup(:a, 1, 1, [2], Symbol[], 2, 2),
                  GateGroup(:b, 2, 2, [3], [:a], 3, 3),
                  GateGroup(:c, 3, 3, [4], [:b], 4, 4)]
        lr = LoweringResult(gates, 4, [1], [2], [1], [1], groups, false)
        c = bennett(lr; strategy=ValueEagerStrategy())
        for x in 0:1
            @test simulate(c, x) == x
        end
        @test verify_reversibility(c)
    end

    @testset "random grouped circuits vs DefaultStrategy" begin
        rng = MersenneTwister(0x47e2)
        n_bad = 0
        for trial in 1:400
            lr = _random_grouped_lr(rng)
            ok = try _value_eager_matches_default(lr, 0:3) catch; false end
            n_bad += !ok
        end
        @test n_bad == 0
    end

    @testset "compiled function still exact: x*x + 3x + 1, all Int8" begin
        f(x::Int8) = x * x + Int8(3) * x + Int8(1)
        lr = Bennett.lower(extract_parsed_ir(f, Tuple{Int8});
                           fold_constants=false)
        c = bennett(lr; strategy=ValueEagerStrategy())
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == f(x)
        end
        @test verify_reversibility(c)
    end
end
