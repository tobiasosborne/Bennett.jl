# Bennett-q9pi — `compose` / `controlled` must respect Bennett-s0tn loop guards,
# and `controlled` must honour its documented contract on every circuit shape.
#
# Source: docs/design/rearch-2026-08/c3-circuit-core.md §2.1(a)/(b), §(d).
#
# (1) `compose(c1, c2)` dropped `loop_check_wires`, AND its trailing
#     reverse-c1 pass uncomputed c1's post-Bennett convergence copy back to 0
#     (so it would have been silently classified as a clean ancilla). An
#     under-unrolled loop inside a composite returned garbage instead of
#     failing loud (CLAUDE.md §1). Fix: carry c2's guards (renumbered) and
#     CNOT-copy each of c1's guard bits onto a fresh loop-check wire before
#     the reverse-c1 pass, so the bit survives the uncompute.
#
# (2) `controlled(c)` copied `loop_check_wires` verbatim. With ctrl=0 no gate
#     fires, the guard stays 0, and `simulate` threw a spurious "did not
#     converge" error. The guard is a *conditional* postcondition
#     (ctrl ⇒ converged). Fix: append `CNOT(ctrl, g); NOT(g)` per guard so
#     the wire ends at `¬ctrl ∨ converged` — 1 whenever ctrl=0, the original
#     convergence bit whenever ctrl=1. Reversible, no LoopGuard change.
#
# (3) `controlled`'s contract `(ctrl, x, 0) → (ctrl, x, ctrl ? f(x) : 0)`.
#     Compiler-produced self-reversing circuits (tabulate / QROM) write their
#     result on FRESH output wires, so the gate-promotion construction
#     already honours the contract — pinned here over all 256 inputs. The
#     only violating shape is input ∩ output ≠ ∅ (a pass-through output
#     aliasing an input wire): with ctrl=0 that output read back `x`, not 0.
#     Fix: re-route each aliased output position to a fresh wire filled by
#     `Toffoli(ctrl, w, fresh)` after the body.

using Test
using Bennett
using Bennett: LoopGuard, lower_tabulate, bennett, NOTGate, CNOTGate,
               ToffoliGate, ReversibleGate

# countdown(x) runs exactly max(x, 0) iterations (Bennett-s0tn's canonical
# example); with K = 8 every x ∈ 9:127 overflows.
function _q9pi_countdown(x::Int8)
    n = x
    steps = Int8(0)
    while n > Int8(0)
        n -= Int8(1)
        steps += Int8(1)
    end
    return steps
end

# popcount(x) via Kernighan: exactly popcount(x) ≤ 8 iterations, so K = 8
# converges on every Int8 (verify_reversibility's random sweep is safe) and
# K = 4 overflows on a data-dependent subset spanning both signs.
function _q9pi_popcount(x::Int8)
    n = x
    c = Int8(0)
    while n != Int8(0)
        n &= n - Int8(1)
        c += Int8(1)
    end
    return c
end

const _Q9PI_ALL_I8 = typemin(Int8):typemax(Int8)

# Run `thunk`; classify the result as (:ok, value) or (:noconv, message).
# Any OTHER error (ancilla-dirty, input-mutated, …) is rethrown so it fails
# the test loud instead of being mistaken for a convergence failure.
function _q9pi_outcome(thunk)
    try
        return (:ok, thunk())
    catch e
        msg = sprint(showerror, e)
        (e isa ErrorException && occursin("did not converge", msg)) || rethrow()
        return (:noconv, msg)
    end
end

_q9pi_loop(f, K) = reversible_compile(f, Int8; optimize=false,
                                      max_loop_iterations=K)

@testset "Bennett-q9pi: compose/controlled respect loop guards + contract" begin

    c_cd8  = _q9pi_loop(_q9pi_countdown, 8)
    c_pc4  = _q9pi_loop(_q9pi_popcount, 4)
    c_pc8  = _q9pi_loop(_q9pi_popcount, 8)
    c_inc  = reversible_compile(x -> x + Int8(1), Int8)
    c_xor  = reversible_compile(x -> x ⊻ Int8(0x55), Int8)

    # Sanity: the fixtures really carry guards, and really overflow.
    @test length(c_cd8.loop_check_wires) == 1
    @test length(c_pc4.loop_check_wires) == 1
    @test length(c_pc8.loop_check_wires) == 1
    @test _q9pi_outcome(() -> simulate(c_cd8, Int8(20)))[1] === :noconv
    @test _q9pi_outcome(() -> simulate(c_pc4, Int8(-1)))[1] === :noconv
    @test all(x -> _q9pi_outcome(() -> simulate(c_pc8, x))[1] === :ok, _Q9PI_ALL_I8)

    @testset "compose: guard on c1 survives the reverse-c1 uncompute" begin
        c12 = compose(c_cd8, c_inc)
        @test length(c12.loop_check_wires) == 1
        @test c12.loop_check_wires[1].K == 8
        @test c12.loop_check_wires[1].header_label ==
              c_cd8.loop_check_wires[1].header_label
        n_noconv = 0
        for x in _Q9PI_ALL_I8
            alone = _q9pi_outcome(() -> simulate(c_cd8, x))
            comp  = _q9pi_outcome(() -> simulate(c12, x))
            @test comp[1] === alone[1]
            if alone[1] === :ok
                @test comp[2] == _q9pi_countdown(x) + Int8(1)
            else
                n_noconv += 1
                @test occursin("max_loop_iterations=8", comp[2])
            end
        end
        @test n_noconv == 127 - 8      # x ∈ 9:127
    end

    @testset "compose: guard on c2 renumbered into the composite" begin
        c12 = compose(c_xor, c_cd8)
        @test length(c12.loop_check_wires) == 1
        for x in _Q9PI_ALL_I8
            y = x ⊻ Int8(0x55)
            alone = _q9pi_outcome(() -> simulate(c_cd8, y))
            comp  = _q9pi_outcome(() -> simulate(c12, x))
            @test comp[1] === alone[1]
            alone[1] === :ok && @test comp[2] == _q9pi_countdown(y)
        end
    end

    @testset "compose: guards on both sides; c1's failure is reported first" begin
        # popcount(K=4) ∘ countdown(K=2). c1 overflows iff popcount(x) > 4
        # (its after-K state is then 4, which also overflows c2) — the error
        # must name c1's bound, the root cause. c2 alone overflows iff
        # popcount(x) ∈ 3:4.
        c_cd2 = _q9pi_loop(_q9pi_countdown, 2)
        c12 = compose(c_pc4, c_cd2)
        @test [lg.K for lg in c12.loop_check_wires] == [4, 2]
        for x in _Q9PI_ALL_I8
            p = count_ones(x)
            comp = _q9pi_outcome(() -> simulate(c12, x))
            if p > 4
                @test comp[1] === :noconv
                @test occursin("max_loop_iterations=4", comp[2])
            elseif p > 2
                @test comp[1] === :noconv
                @test occursin("max_loop_iterations=2", comp[2])
            else
                @test comp == (:ok, Int8(p))
            end
        end
    end

    @testset "compose: converging loop composite is exact + reversible" begin
        c12 = compose(c_pc8, c_inc)
        c21 = compose(c_inc, c_pc8)
        for x in _Q9PI_ALL_I8
            @test simulate(c12, x) == _q9pi_popcount(x) + Int8(1)
            @test simulate(c21, x) == _q9pi_popcount(x + Int8(1))
        end
        @test verify_reversibility(c12; n_tests=64)
        @test verify_reversibility(c21; n_tests=64)
        # Nested: the inner composite's guard wire is itself uncomputed by
        # the outer reverse pass and must be re-copied.
        c3 = compose(compose(c_pc8, c_inc), c_pc8)
        @test length(c3.loop_check_wires) == 2
        for x in _Q9PI_ALL_I8
            @test simulate(c3, x) == _q9pi_popcount(_q9pi_popcount(x) + Int8(1))
        end
        @test verify_reversibility(c3; n_tests=32)
    end

    @testset "compose: loop-free circuits unchanged (no extra wires/gates)" begin
        c12 = compose(c_inc, c_xor)
        @test isempty(c12.loop_check_wires)
        @test c12.n_wires == c_inc.n_wires + c_xor.n_wires - 8
        @test length(c12.gates) == 2 * length(c_inc.gates) + length(c_xor.gates)
    end

    @testset "controlled: ctrl=0 never fires the guard; ctrl=1 still does" begin
        cc = controlled(c_cd8)
        @test length(cc.circuit.loop_check_wires) == 1
        for x in _Q9PI_ALL_I8
            @test simulate(cc, false, x) == 0
            alone = _q9pi_outcome(() -> simulate(c_cd8, x))
            on    = _q9pi_outcome(() -> simulate(cc, true, x))
            @test on[1] === alone[1]
            on[1] === :ok && @test on[2] == _q9pi_countdown(x)
        end
    end

    @testset "controlled: converging loop, both ctrl values, reversible" begin
        cc = controlled(c_pc8)
        for x in _Q9PI_ALL_I8
            @test simulate(cc, true,  x) == _q9pi_popcount(x)
            @test simulate(cc, false, x) == 0
        end
        # Random (ctrl, x) probes — must not trip the guard on ctrl=0.
        @test verify_reversibility(cc; n_tests=64)
    end

    @testset "controlled ∘ compose: guards from both stages conditional" begin
        cc = controlled(compose(c_pc4, c_inc))
        for x in _Q9PI_ALL_I8
            @test simulate(cc, false, x) == 0
            on = _q9pi_outcome(() -> simulate(cc, true, x))
            if count_ones(x) > 4
                @test on[1] === :noconv
            else
                @test on == (:ok, _q9pi_popcount(x) + Int8(1))
            end
        end
    end

    @testset "controlled: loop-free gate stream is exactly the promotion" begin
        cc = controlled(c_inc)
        expected = sum(g -> g isa ToffoliGate ? 3 : 1, c_inc.gates)
        @test length(cc.circuit.gates) == expected
        @test cc.circuit.n_wires == c_inc.n_wires + 2   # ctrl + Toffoli anc
    end

    @testset "controlled: self-reversing (tabulate/QROM) honours contract" begin
        f(x::Int8) = x * x + Int8(3)
        lr = lower_tabulate(f, Tuple{Int8}, [8]; out_width=8)
        @test lr.self_reversing           # genuinely the self-reversing path
        c = bennett(lr)
        @test length(c.gates) == length(lr.gates)   # fast path, no wrap
        @test isempty(intersect(Set(c.input_wires), Set(c.output_wires)))
        cc = controlled(c)
        for x in _Q9PI_ALL_I8
            @test simulate(cc, true,  x) == f(x)
            @test simulate(cc, false, x) == 0
        end
        @test verify_reversibility(cc; n_tests=64)
        # Same via the public entry point.
        cp = controlled(reversible_compile(f, Int8; strategy=:tabulate))
        for x in _Q9PI_ALL_I8
            @test simulate(cp, true,  x) == f(x)
            @test simulate(cp, false, x) == 0
        end
        # compose's "self-reversing" rejection is really an input∩output
        # overlap check: a self-reversing tabulate circuit has disjoint
        # input/output wires and composes correctly on both sides.
        for (cc2, g) in ((compose(c, c_inc), x -> f(x) + Int8(1)),
                         (compose(c_inc, c), x -> f(x + Int8(1))))
            for x in _Q9PI_ALL_I8
                @test simulate(cc2, x) == g(x)
            end
            @test verify_reversibility(cc2; n_tests=64)
        end
    end

    @testset "controlled: input∩output pass-through output is 0 when ctrl=0" begin
        # Hand-built identity: output wires ARE the input wires, no gates.
        # The ReversibleCircuit constructor permits input ∩ output ≠ ∅.
        id8 = ReversibleCircuit(8, ReversibleGate[], collect(1:8),
                                collect(1:8), Int[], [8], [8])
        cc = controlled(id8)
        @test isempty(intersect(Set(cc.circuit.input_wires),
                                Set(cc.circuit.output_wires)))
        for x in _Q9PI_ALL_I8
            @test simulate(cc, true,  x) == x
            @test simulate(cc, false, x) == 0
        end
        @test verify_reversibility(cc; n_tests=64)

        # Mixed: (x, x+1) where the first output aliases the input wires
        # and the second lives on c_inc's fresh output wires.
        pair = ReversibleCircuit(c_inc.n_wires, c_inc.gates, c_inc.input_wires,
                                 vcat(c_inc.input_wires, c_inc.output_wires),
                                 c_inc.ancilla_wires, [8], [8, 8])
        for x in _Q9PI_ALL_I8
            @test simulate(pair, x) == (x, x + Int8(1))   # fixture sanity
        end
        ccp = controlled(pair)
        for x in _Q9PI_ALL_I8
            @test simulate(ccp, true,  x) == (x, x + Int8(1))
            @test simulate(ccp, false, x) == (Int8(0), Int8(0))
        end
        @test verify_reversibility(ccp; n_tests=64)
    end
end
