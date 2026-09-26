# Bennett-ukup: `verify_reversibility(c; n_tests=0)` / `n_tests=-1` returned
# `true` without executing a single probe — a vacuous success certificate
# indistinguishable from a real pass (Astra 2026-09-26 B-circuit-core F12).
# The `ControlledCircuit` overload delegated and inherited the hole.
#
# Post-fix contract: a non-positive budget is a caller error and throws
# `ArgumentError` before anything runs; a positive budget still executes and
# still detects the fixture's unconditional ancilla violation.

using Test
using Bennett
using Bennett: ReversibleCircuit, ReversibleGate, NOTGate, CNOTGate,
               controlled, verify_reversibility, simulate, reversible_compile

@testset "Bennett-ukup: verify_reversibility rejects non-positive budgets" begin
    # Dirty fixture: input=[1], output=[2], ancilla=[3]; NOTGate(3) leaves
    # the ancilla at 1 on every input.
    dirty() = ReversibleCircuit(3, ReversibleGate[NOTGate(3)], [1], [2], [3], [1], [1])

    @testset "ReversibleCircuit: budget 0 / -1 throw ArgumentError" begin
        c = dirty()
        for n in (0, -1, -100)
            @test_throws ArgumentError verify_reversibility(c; n_tests=n)
        end
        err = try verify_reversibility(c; n_tests=0); nothing catch e; e end
        @test err isa ArgumentError
        @test occursin("n_tests", sprint(showerror, err))
    end

    @testset "ReversibleCircuit: budget 1 executes and catches the dirty ancilla" begin
        c = dirty()
        err = try verify_reversibility(c; n_tests=1); nothing catch e; e end
        @test err isa ErrorException
        @test occursin("ancilla wire 3 not zero", sprint(showerror, err))
    end

    @testset "ControlledCircuit: budget 0 / -1 throw ArgumentError" begin
        cc = controlled(dirty())
        for n in (0, -1)
            @test_throws ArgumentError verify_reversibility(cc; n_tests=n)
        end
    end

    @testset "clean compiled Int8 increment still verifies" begin
        c = reversible_compile(x -> x + Int8(1), Int8)
        @test verify_reversibility(c) === true
        @test verify_reversibility(c; n_tests=1) === true
        for x in typemin(Int8):typemax(Int8)
            @test simulate(c, x) == x + Int8(1)
        end
        cc = controlled(c)
        @test verify_reversibility(cc; n_tests=20) === true
        @test_throws ArgumentError verify_reversibility(cc; n_tests=0)
    end
end
