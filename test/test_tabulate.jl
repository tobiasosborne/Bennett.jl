using Test
using Bennett
using Bennett: ToffoliGate, lower_tabulate, bennett

# Bennett-iwj6: the `bit_width=W` (narrowed) tabulate cases below used to
# assert that `strategy=:tabulate` returns the NATURAL-WIDTH function masked
# to W bits — which is not the function `bit_width=W` asks for, and not the one
# `strategy=:expression` computes (that one does W-bit modular arithmetic, sign
# bit at W-1, intermediates wrapping mod 2^W). Every one of them therefore
# asserted the miscompiled value. The public entry point now refuses narrowed
# tabulation (explicit `:tabulate` raises, `:auto` falls through to
# expression), so those testsets now assert the refusal, and the QROM
# acceptance spec for small W is pinned at the `lower_tabulate` level — the
# layer that still takes an explicit narrow width.
@testset "Tabulate strategy: QROM lookup for small-W pure functions" begin

    @testset "Acceptance: x^2 + 3x + 1 at W=2" begin
        f(x::Int8) = x*x + Int8(3)*x + Int8(1)
        # Spec: ≤10 wires, ≤15 Toffoli. Reached through `lower_tabulate`
        # directly — `reversible_compile` no longer routes a narrowed compile
        # here (Bennett-iwj6, see the header).
        lr = lower_tabulate(f, Tuple{Int8}, [2]; out_width=2)
        c = bennett(lr)

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

    # Bennett-iwj6: narrowed tabulation is a miscompile, not a strategy
    # choice. `bit_width=W` with W ≠ the argument's natural width means W-bit
    # modular arithmetic, which a table over the natural-width `f` cannot
    # express; `:tabulate` refuses and `:auto` compiles the expression.
    @testset "x + 1 @ W=2 is refused as narrowed" begin
        g(x::Int8) = x + Int8(1)
        @test_throws ArgumentError reversible_compile(g, Int8; bit_width=2, strategy=:tabulate)
        @test_throws "Bennett-iwj6" reversible_compile(g, Int8; bit_width=2, strategy=:tabulate)
    end

    @testset "x * x @ W=2 is refused as narrowed" begin
        h(x::Int8) = x * x
        @test_throws ArgumentError reversible_compile(h, Int8; bit_width=2, strategy=:tabulate)
    end

    @testset "3x + 1 @ W=2 is refused as narrowed" begin
        p(x::Int8) = Int8(3)*x + Int8(1)
        @test_throws ArgumentError reversible_compile(p, Int8; bit_width=2, strategy=:tabulate)
    end

    @testset "W=4, x^2 + 3 is refused as narrowed" begin
        f(x::Int8) = x*x + Int8(3)
        @test_throws ArgumentError reversible_compile(f, Int8; bit_width=4, strategy=:tabulate)
    end

    @testset "Two-arg: a + b @ W=2 is refused as narrowed" begin
        f(a::Int8, b::Int8) = a + b
        @test_throws ArgumentError reversible_compile(f, Int8, Int8; bit_width=2, strategy=:tabulate)
    end

    @testset "Two-arg: a * b @ W=2 is refused as narrowed" begin
        f(a::Int8, b::Int8) = a * b
        @test_throws ArgumentError reversible_compile(f, Int8, Int8; bit_width=2, strategy=:tabulate)
    end

    @testset ":auto does not tabulate a narrowed compile (Bennett-iwj6)" begin
        # The cost model used to divert W=2 here and hand back a table of the
        # natural-width function — a different function from the one the
        # narrowing asks for. `:auto` must now be the expression circuit.
        f(x::Int8) = x*x + Int8(3)*x + Int8(1)
        c_auto = reversible_compile(f, Int8; bit_width=2)  # default :auto
        c_expr = reversible_compile(f, Int8; bit_width=2, strategy=:expression)
        @test gate_count(c_auto) == gate_count(c_expr)
        @test c_auto.n_wires == c_expr.n_wires
        @test verify_reversibility(c_auto)
        for x in 0:3
            @test simulate(c_auto, Int8(x)) == simulate(c_expr, Int8(x))
        end
        @test_throws ArgumentError reversible_compile(f, Int8; bit_width=2, strategy=:tabulate)
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
        @test_throws ArgumentError reversible_compile(f, Int8; strategy=:nope)
    end

    @testset "non-integer arg type rejects :tabulate explicitly" begin
        # Float64 path: bit_width doesn't apply, 2^64 table is absurd.
        # Explicit :tabulate should error clearly.
        f(x::Float64) = x + 1.0
        @test_throws ArgumentError reversible_compile(f, Float64; strategy=:tabulate)
    end

    @testset "identity at natural width (exhaustive 256 inputs)" begin
        # Bennett-iwj6: `bit_width=3` no longer tabulates (narrowed). The
        # natural-width table is still tabulated, with `out_width` taken from
        # the return type (Int8 → 8).
        id(x::Int8) = x
        c = reversible_compile(id, Int8; strategy=:tabulate)
        @test c.output_elem_widths == [8]
        for x in Int8(-128):Int8(127)
            @test simulate(c, x) == id(x)
        end
        @test verify_reversibility(c)
    end
end
