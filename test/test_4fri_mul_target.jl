using Test
using Bennett

# Bennett-4fri / U30: `:auto` mul dispatcher never picked `:qcla_tree`
# or `:karatsuba` — defaulted to `:shift_add` for every width. The
# README's 6× T-depth win at W=32/64 was locked behind an opt-in. The
# fix is a `target` kwarg: `target=:gate_count` (default) preserves
# the shift-and-add choice; `target=:depth` promotes `:auto` to
# `:qcla_tree`, which has strictly better Toffoli-depth.
#
# This pins:
#   1. Default behaviour unchanged (`target=:gate_count`, shift-and-add).
#   2. `target=:depth` flips `:auto` to `qcla_tree` at W=32 with a
#      ≥3× Toffoli-depth reduction.
#   3. Explicit `mul=:shift_add` still wins over a `target=:depth`
#      preference (user intent is authoritative).
#   4. Invalid `target` values raise ArgumentError naming the valid set.
#   5. The kwarg is reachable on all three `reversible_compile` overloads
#      (Tuple / Float64 / ParsedIR).
@testset "Bennett-4fri / U30: mul dispatcher target kwarg" begin

    @testset "default target unchanged (:gate_count → shift_add at W=32)" begin
        # Without `target`, W=32 multiplication must retain the pre-U30
        # shift-and-add baseline (matches test_gate_count_regression.jl
        # style, but on a fresh `x * y` pattern).
        c = reversible_compile((x, y) -> x * y, Int32, Int32; fold_constants=false)
        # Shift-and-add Toffoli-depth at W=32: 190. Anchor.
        @test toffoli_depth(c) == 190
        @test verify_reversibility(c)
    end

    @testset "target=:depth flips :auto to qcla_tree (≥3× depth reduction)" begin
        c_def = reversible_compile((x, y) -> x * y, Int32, Int32;
                                   fold_constants=false)
        c_dep = reversible_compile((x, y) -> x * y, Int32, Int32;
                                   target=:depth, fold_constants=false)
        @test verify_reversibility(c_def)
        @test verify_reversibility(c_dep)
        # Pin the 3× depth reduction advertised in the U30 catalogue.
        @test toffoli_depth(c_dep) * 3 <= toffoli_depth(c_def)
        # Same outputs on a range of inputs.
        for x in Int32.([0, 1, 3, -7, 100]), y in Int32.([0, 1, -4, 11, 255])
            @test simulate(c_def, (x, y)) == simulate(c_dep, (x, y))
        end
    end

    @testset "explicit mul=:shift_add overrides target=:depth" begin
        # User intent beats the heuristic.
        c = reversible_compile((x, y) -> x * y, Int32, Int32;
                               target=:depth, mul=:shift_add,
                               fold_constants=false)
        @test toffoli_depth(c) == 190   # still shift-and-add baseline
    end

    @testset "invalid target rejected with ArgumentError" begin
        err = try
            reversible_compile((x, y) -> x * y, Int32, Int32; target=:bogus)
            nothing
        catch e; e; end
        @test err isa ArgumentError
        @test occursin("target", err.msg)
    end

    @testset "target kwarg reachable on all three overloads" begin
        # Tuple
        @test reversible_compile((x, y) -> x * y, Int32, Int32; target=:depth) isa ReversibleCircuit
        # ParsedIR
        parsed = Bennett.extract_parsed_ir((x, y) -> x * y,
                                           Tuple{Int32, Int32})
        @test reversible_compile(parsed; target=:depth) isa ReversibleCircuit
        # Float64 — soft-float internally multiplies UInt64 mantissas,
        # so target propagation matters there too.
        @test reversible_compile((x, y) -> x * y, Float64, Float64; target=:depth) isa ReversibleCircuit
    end
end
