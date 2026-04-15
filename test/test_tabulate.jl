using Test
using Bennett
using Bennett: ToffoliGate

@testset "Tabulate strategy: QROM lookup for small-W pure functions" begin

    @testset "Acceptance: x^2 + 3x + 1 at W=2" begin
        f(x::Int8) = x*x + Int8(3)*x + Int8(1)
        c = reversible_compile(f, Int8; bit_width=2, strategy=:tabulate)

        # Spec: ≤10 wires, ≤15 Toffoli
        @test c.n_wires <= 10
        @test count(g -> g isa ToffoliGate, c.gates) <= 15

        # All 4 inputs correct (compare low 2 bits)
        for x in 0:3
            expected = (f(Int8(x))) & Int8(0x3)
            got = simulate(c, Int8(x)) & Int8(0x3)
            @test got == expected
        end

        @test verify_reversibility(c)
        println("  Tabulate x^2+3x+1 @ W=2: $(gate_count(c).total) gates, " *
                "$(count(g->g isa ToffoliGate, c.gates)) Toffoli, $(c.n_wires) wires")
    end

    @testset "x + 1 @ W=2" begin
        g(x::Int8) = x + Int8(1)
        c = reversible_compile(g, Int8; bit_width=2, strategy=:tabulate)
        for x in 0:3
            @test simulate(c, Int8(x)) & Int8(0x3) == (x + 1) & 0x3
        end
        @test verify_reversibility(c)
    end

    @testset "x * x @ W=2" begin
        h(x::Int8) = x * x
        c = reversible_compile(h, Int8; bit_width=2, strategy=:tabulate)
        for x in 0:3
            @test simulate(c, Int8(x)) & Int8(0x3) == (x*x) & 0x3
        end
        @test verify_reversibility(c)
    end

    @testset "3x + 1 @ W=2" begin
        p(x::Int8) = Int8(3)*x + Int8(1)
        c = reversible_compile(p, Int8; bit_width=2, strategy=:tabulate)
        for x in 0:3
            @test simulate(c, Int8(x)) & Int8(0x3) == (3*x + 1) & 0x3
        end
        @test verify_reversibility(c)
    end

    @testset "W=4, x^2 + 3 (exhaustive 16 inputs)" begin
        f(x::Int8) = x*x + Int8(3)
        c = reversible_compile(f, Int8; bit_width=4, strategy=:tabulate)
        for x in 0:15
            expected = (x*x + 3) & 0xf
            got = simulate(c, Int8(x)) & Int8(0xf)
            @test got == expected
        end
        @test verify_reversibility(c)
    end

    @testset "Two-arg: a + b @ W=2" begin
        f(a::Int8, b::Int8) = a + b
        c = reversible_compile(f, Int8, Int8; bit_width=2, strategy=:tabulate)
        for a in 0:3, b in 0:3
            @test simulate(c, (Int8(a), Int8(b))) & Int8(0x3) == (a + b) & 0x3
        end
        @test verify_reversibility(c)
    end

    @testset "Two-arg: a * b @ W=2" begin
        f(a::Int8, b::Int8) = a * b
        c = reversible_compile(f, Int8, Int8; bit_width=2, strategy=:tabulate)
        for a in 0:3, b in 0:3
            @test simulate(c, (Int8(a), Int8(b))) & Int8(0x3) == (a*b) & 0x3
        end
        @test verify_reversibility(c)
    end

    @testset ":auto picks tabulate at W=2 (cost-model win)" begin
        f(x::Int8) = x*x + Int8(3)*x + Int8(1)
        c_auto = reversible_compile(f, Int8; bit_width=2)  # default :auto
        c_tab  = reversible_compile(f, Int8; bit_width=2, strategy=:tabulate)
        # Auto should converge on tabulate → same wire/gate count.
        @test c_auto.n_wires == c_tab.n_wires
        @test length(c_auto.gates) == length(c_tab.gates)

        # And must be much smaller than the expression-graph path.
        c_force = reversible_compile(f, Int8; bit_width=2, strategy=:expression)
        @test c_tab.n_wires < c_force.n_wires
    end

    @testset ":auto falls through to expression path at W=8" begin
        f(x::Int8) = x + Int8(3)
        c_auto = reversible_compile(f, Int8)  # W=8 natural
        # Tabulate at W=8 would be 256 entries × 8 bits (wasteful);
        # auto should pick the expression path.
        # The existing i8 x+3 baseline is 100 gates (post-path-predicate, per WORKLOG).
        @test gate_count(c_auto).total <= 150
        @test gate_count(c_auto).total >= 50  # lower bound — not a zero-gate tabulate
    end

    @testset "explicit :expression forces the normal compile path" begin
        f(x::Int8) = x + Int8(1)
        c_expr = reversible_compile(f, Int8; bit_width=2, strategy=:expression)
        for x in 0:3
            @test simulate(c_expr, Int8(x)) & Int8(0x3) == (x + 1) & 0x3
        end
        @test verify_reversibility(c_expr)
    end

    @testset "unknown strategy errors" begin
        f(x::Int8) = x + Int8(1)
        @test_throws ErrorException reversible_compile(f, Int8; strategy=:nope)
    end

    @testset "non-integer arg type rejects :tabulate explicitly" begin
        # Float64 path: bit_width doesn't apply, 2^64 table is absurd.
        # Explicit :tabulate should error clearly.
        f(x::Float64) = x + 1.0
        @test_throws ErrorException reversible_compile(f, Float64; strategy=:tabulate)
    end

    @testset "identity at W=3 (8 inputs)" begin
        id(x::Int8) = x
        c = reversible_compile(id, Int8; bit_width=3, strategy=:tabulate)
        for x in 0:7
            @test simulate(c, Int8(x)) & Int8(0x7) == x & 0x7
        end
        @test verify_reversibility(c)
    end
end
