# Bennett-7c5u — n-ary `compose(c1, c2, ..., cn)`: a pipeline costs a gate
# count LINEAR in n.
#
# Source: Astra review F22 (reviews/2026-09-26-astra/B-circuit-core.md).
# Binary `compose(c1, c2)` embeds c1 twice (forward + uncompute). Folding
# from the left, `l = compose(l, a)`, therefore embeds the whole composite
# twice per stage: 58·(2^n − 1) gates for n stages of `x + 1`.
#
# Invariant: `compose(c1, ..., cn)` emits c1 … cn forward, then uncomputes
# each intermediate stage once, in reverse order, so
#     gates = Σ|ck| + Σ_{k<n} |ck| + Σ_{k<n} guards(ck)
#     wires = n_wires(c1) + Σ_{k≥2} (n_wires(ck) − |inputs(ck)|) + Σ_{k<n} guards(ck)
# every intermediate ancilla returns to zero, every stage's loop guard is
# carried (in stage order), and the 2-argument case is the existing binary
# `compose` gate-for-gate.

using Test
using Bennett
using Bennett: LoopGuard

const _7C5U_ALL_I8 = typemin(Int8):typemax(Int8)

function _7c5u_popcount(x::Int8)
    n = x
    c = Int8(0)
    while n != Int8(0)
        n &= n - Int8(1)
        c += Int8(1)
    end
    return c
end

_7c5u_loop(K) = reversible_compile(_7c5u_popcount, Int8; optimize=false,
                                   max_loop_iterations=K)

_7c5u_gates(cs) = sum(c -> length(c.gates), cs) +
                  sum(c -> length(c.gates) + length(c.loop_check_wires), cs[1:end-1])
_7c5u_wires(cs) = cs[1].n_wires +
                  sum(c -> c.n_wires - length(c.input_wires), cs[2:end]) +
                  sum(c -> length(c.loop_check_wires), cs[1:end-1])

function _7c5u_outcome(thunk)
    try
        return (:ok, thunk())
    catch e
        msg = sprint(showerror, e)
        (e isa ErrorException && occursin("did not converge", msg)) || rethrow()
        return (:noconv, msg)
    end
end

@testset "Bennett-7c5u: n-ary compose is linear in the number of stages" begin
    a = reversible_compile(x -> x + Int8(1), Int8)
    @test length(a.gates) == 58          # CLAUDE.md §6 baseline, unchanged

    @testset "n stages of x+1, n = 2..8" begin
        for n in 2:8
            cs = fill(a, n)
            cn = compose(cs...)
            # Exact linear formula: 58·(2n − 1) gates, 41 + 33(n − 1) wires.
            @test length(cn.gates) == _7c5u_gates(cs) == 58 * (2n - 1)
            @test cn.n_wires == _7c5u_wires(cs) == a.n_wires + (n - 1) * (a.n_wires - 8)
            @test compose(cs).gates == cn.gates   # vector form == varargs form
            @test verify_reversibility(cn; n_tests=64)
            for x in _7C5U_ALL_I8
                @test simulate(cn, x) == x + Int8(n)
            end
            # Right fold is already linear and agrees on every input.
            r = foldr(compose, cs)
            @test length(r.gates) == length(cn.gates)
            # Left fold of BINARY compose: documented exponential cost
            # (the composite carries no stage list); still the same function.
            if n <= 6
                l = foldl(compose, cs)
                @test length(l.gates) == 58 * (2^n - 1)
                for x in _7C5U_ALL_I8
                    @test simulate(l, x) == simulate(r, x) == simulate(cn, x)
                end
            end
        end
    end

    @testset "binary case is the existing compose" begin
        c_xor = reversible_compile(x -> x ⊻ Int8(0x55), Int8)
        c_pc8 = _7c5u_loop(8)
        for (p, q) in ((a, c_xor), (c_pc8, a), (a, c_pc8), (c_pc8, c_pc8))
            b = compose(p, q)
            v = compose([p, q])
            @test b.gates == v.gates
            @test b.n_wires == v.n_wires == _7c5u_wires([p, q])
            @test length(b.gates) == _7c5u_gates([p, q])
            @test b.loop_check_wires == v.loop_check_wires
        end
    end

    @testset "three different stages incl. a data-dependent loop" begin
        c_xor = reversible_compile(x -> x ⊻ Int8(0x55), Int8)
        c_pc8 = _7c5u_loop(8)
        f(x) = _7c5u_popcount(x ⊻ Int8(0x55)) + Int8(1)
        cs = [c_xor, c_pc8, a]
        c3 = compose(cs...)
        @test length(c3.gates) == _7c5u_gates(cs)
        @test c3.n_wires == _7c5u_wires(cs)
        @test length(c3.loop_check_wires) == 1 && c3.loop_check_wires[1].K == 8
        for x in _7C5U_ALL_I8
            @test simulate(c3, x) == f(x)
        end
        @test verify_reversibility(c3; n_tests=64)
        l = compose(compose(c_xor, c_pc8), a)
        r = compose(c_xor, compose(c_pc8, a))
        for x in _7C5U_ALL_I8
            @test simulate(l, x) == simulate(r, x) == f(x)
        end

        # Loop at the FRONT and at the BACK as well (guard copy vs renumber).
        c4 = compose(c_pc8, c_xor, a, c_pc8)
        @test [lg.K for lg in c4.loop_check_wires] == [8, 8]
        @test length(c4.gates) == _7c5u_gates([c_pc8, c_xor, a, c_pc8])
        for x in _7C5U_ALL_I8
            @test simulate(c4, x) ==
                  _7c5u_popcount((_7c5u_popcount(x) ⊻ Int8(0x55)) + Int8(1))
        end
        @test verify_reversibility(c4; n_tests=32)
    end

    @testset "every stage's guard fires; earliest failing stage reported" begin
        # pc4 overflows iff popcount > 4. Stages: pc4, xor, pc4 (guards K=4, K=4
        # distinguished by order), then inc. Middle-stage guards are CNOT-copied
        # before that stage is uncomputed; without the copy they read 0.
        c_pc4 = _7c5u_loop(4)
        c_pc3 = _7c5u_loop(3)
        c_xor = reversible_compile(x -> x ⊻ Int8(0x55), Int8)
        c = compose(c_pc4, c_xor, c_pc3, a)
        @test [lg.K for lg in c.loop_check_wires] == [4, 3]
        n_bad1 = n_bad2 = 0
        for x in _7C5U_ALL_I8
            out = _7c5u_outcome(() -> simulate(c, x))
            p1 = count_ones(x)
            if p1 > 4
                n_bad1 += 1
                @test out[1] === :noconv && occursin("max_loop_iterations=4", out[2])
                continue
            end
            y = Int8(p1) ⊻ Int8(0x55)
            if count_ones(y) > 3
                n_bad2 += 1
                @test out[1] === :noconv && occursin("max_loop_iterations=3", out[2])
            else
                @test out == (:ok, Int8(count_ones(y)) + Int8(1))
            end
        end
        @test n_bad1 > 0 && n_bad2 > 0
    end

    @testset "controlled(compose(...)) smoke" begin
        c_xor = reversible_compile(x -> x ⊻ Int8(0x55), Int8)
        cc = controlled(compose(c_xor, _7c5u_loop(8), a))
        for x in _7C5U_ALL_I8
            @test simulate(cc, false, x) == 0
            @test simulate(cc, true, x) == _7c5u_popcount(x ⊻ Int8(0x55)) + Int8(1)
        end
        @test verify_reversibility(cc; n_tests=32)
    end

    @testset "preconditions fail loud, naming the stage" begin
        c16 = reversible_compile(x -> x + Int16(1), Int16)
        err = try compose(a, a, c16); nothing catch e; e end
        @test err isa ArgumentError
        @test occursin("c2.output_elem_widths", sprint(showerror, err))
        @test occursin("c3.input_widths", sprint(showerror, err))
        @test_throws ArgumentError compose(ReversibleCircuit[])
        @test compose([a]) === a
    end
end
