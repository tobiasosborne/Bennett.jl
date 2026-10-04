using Test, Bennett
using Random

# Bennett-bnfk: `target=:depth` must never resolve an `:auto` arithmetic
# strategy to one that is DEEPER (toffoli_depth) than what `target=:gate_count`
# resolves to. Before the fix `mul=:auto` + `target=:depth` went to qcla_tree
# at every width, which (under the corrected Bennett-u3b2 metric) is deeper
# at W=8/16/32 (112/176/256 vs 36/84/180) and, inlined into soft_fmul at
# W=64, deeper too (3382 vs 3104) — besides costing ~8x the Toffolis.
#
# Invariant tested over op × W (and through the Float64 soft-float callees,
# which Bennett-0a6f now lowers under the caller's options):
#     toffoli_depth(target=:depth) <= toffoli_depth(target=:gate_count)
# with the output correct vs native Julia and all ancillae returned to zero.

const BNFK_TYPES = (Int8, Int16, Int32, Int64)
const BNFK_OPS = (("+", (x, y) -> x + y), ("-", (x, y) -> x - y), ("*", (x, y) -> x * y))

function bnfk_inputs(T)
    T === Int8 && return [(x, y) for x in typemin(Int8):typemax(Int8)
                                 for y in typemin(Int8):typemax(Int8)]
    rng = MersenneTwister(0xb0f1)
    edges = T[0, 1, -1, typemin(T), typemax(T), 2, -2]
    pts = [(x, y) for x in edges for y in edges]
    append!(pts, [(rand(rng, T), rand(rng, T)) for _ in 1:40])
    return pts
end

@testset "Bennett-bnfk: target=:depth never deeper than target=:gate_count" begin
    @testset "strategy resolution: :auto under :depth is never deeper" begin
        # Per the measured table in `_pick_mul_strategy`'s docstring no
        # lowerable width (W <= 64) favours qcla_tree, so :depth and
        # :gate_count resolve `mul=:auto` identically there.
        for W in 1:64
            @test Bennett._pick_mul_strategy(:auto, W; target=:depth) ===
                  Bennett._pick_mul_strategy(:auto, W; target=:gate_count) === :shift_add
            @test Bennett._pick_add_strategy(:auto, W) === :ripple
        end
        # Explicit choices are user intent — untouched by target.
        for t in (:gate_count, :depth), W in (8, 64)
            @test Bennett._pick_mul_strategy(:qcla_tree, W; target=t) === :qcla_tree
            @test Bennett._pick_mul_strategy(:shift_add, W; target=t) === :shift_add
        end
        @test_throws ArgumentError Bennett._pick_mul_strategy(:auto, 8; target=:bogus)
    end

    @testset "$name at $T" for (name, f) in BNFK_OPS, T in BNFK_TYPES
        c_gc  = reversible_compile(f, T, T)
        c_dep = reversible_compile(f, T, T; target=:depth)
        @test toffoli_depth(c_dep) <= toffoli_depth(c_gc)
        @test gate_count(c_dep).total <= gate_count(c_gc).total
        for (x, y) in bnfk_inputs(T)
            @test simulate(c_dep, (x, y)) == f(x, y)
        end
        @test verify_reversibility(c_dep)
    end

    @testset "Float64 $name via soft-float callees" for (name, f) in (("*", (x, y) -> x * y),
                                                                       ("+", (x, y) -> x + y))
        c_gc  = reversible_compile(f, Float64, Float64)
        c_dep = reversible_compile(f, Float64, Float64; target=:depth)
        @test toffoli_depth(c_dep) <= toffoli_depth(c_gc)
        for (a, b) in ((1.5, 2.25), (-3.0, 7.0), (0.1, 0.2), (1.0e300, 1.0e10),
                       (5.0e-324, 0.5), (-0.0, 3.0), (Inf, 2.0), (2.0^-1022, 2.0^-3))
            r = simulate(c_dep, (reinterpret(UInt64, a), reinterpret(UInt64, b)))
            @test reinterpret(UInt64, r) == reinterpret(UInt64, f(a, b))
        end
        @test verify_reversibility(c_dep; n_tests=3)
    end
end
