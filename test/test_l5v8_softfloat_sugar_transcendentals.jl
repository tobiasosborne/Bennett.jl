# Bennett-l5v8: Base.sin (and sibling transcendentals) on SoftFloat.
#
# The Float64 sugar overload `reversible_compile(f, Float64)` wraps the user
# function as `x -> (@inline f(SoftFloat(x))).bits`. For `f = sin` this died
# at the dq8l/U81 VoidType wall: no `Base.sin(::SoftFloat)` method existed,
# so Julia compiled the wrapper to a `jl_f_throw_methoderror` + `unreachable`
# body with a `void` return type, which extraction refuses. The soft
# primitives (soft_sin, soft_cos, ...) all existed and were registered as
# callees — only the SoftFloat dispatch overloads were missing.
#
# Three layers:
#   1. Dispatch plumbing: `f(SoftFloat(x)).bits === soft_f(bits(x))` bit-exact
#      for every new overload, over random + special inputs. (The overload is
#      a direct forwarder, so equality must be exact — accuracy vs Base.f is
#      the primitive's own contract, tested in its bit-level test file.)
#   2. Extraction: the sin sugar wrapper extracts to ParsedIR containing a
#      soft_sin call (regression for the VoidType wall).
#   3. E2E: `reversible_compile(sin, Float64)` — the talk's "Base.sin,
#      compiled unchanged" claim — verifies reversibility and matches
#      Base.sin to <= 2 ulp on sampled inputs.

using Test
using Random
using Bennett

const _SPECIAL_INPUTS = Float64[
    0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 2.0, -2.0,
    pi/4, -pi/4, pi/2, pi, 100.0, 1e6, 1e10, 1e-8,
    Inf, -Inf, NaN,
    5.0e-324, -5.0e-324,                 # subnormals
    2.2250738585072014e-308,             # smallest normal
    1.7976931348623157e308, -1.7976931348623157e308,
]

# (Base function, soft primitive) pairs for every unary overload added by
# Bennett-l5v8. exp/exp2/sqrt predate l5v8 and keep their own tests.
const _UNARY_PAIRS = [
    (sin,   Bennett.soft_sin),
    (cos,   Bennett.soft_cos),
    (tan,   Bennett.soft_tan),
    (asin,  Bennett.soft_asin),
    (acos,  Bennett.soft_acos),
    (atan,  Bennett.soft_atan),
    (sinh,  Bennett.soft_sinh),
    (cosh,  Bennett.soft_cosh),
    (tanh,  Bennett.soft_tanh),
    (asinh, Bennett.soft_asinh),
    (acosh, Bennett.soft_acosh),
    (atanh, Bennett.soft_atanh),
    (log,   Bennett.soft_log),
    (log2,  Bennett.soft_log2),
    (log10, Bennett.soft_log10),
    (log1p, Bennett.soft_log1p),
    (expm1, Bennett.soft_expm1),
]

@testset "Bennett-l5v8: SoftFloat transcendental sugar" begin

    @testset "unary dispatch plumbing is bit-exact vs primitive" begin
        rng = MersenneTwister(0x15a8)
        rand_inputs = [reinterpret(Float64, rand(rng, UInt64)) for _ in 1:200]
        for (base_f, soft_f) in _UNARY_PAIRS
            for x in vcat(_SPECIAL_INPUTS, rand_inputs)
                xb = reinterpret(UInt64, x)
                @test base_f(Bennett.SoftFloat(xb)).bits === soft_f(xb)
            end
        end
    end

    @testset "atan(y, x) dispatch plumbing" begin
        rng = MersenneTwister(0x17a2)
        pts = [(reinterpret(Float64, rand(rng, UInt64)),
                reinterpret(Float64, rand(rng, UInt64))) for _ in 1:100]
        for (y, x) in vcat([(1.0, 1.0), (0.0, -0.0), (-0.0, 0.0), (Inf, -Inf),
                            (NaN, 1.0), (1.0, NaN)], pts)
            yb = reinterpret(UInt64, y); xb = reinterpret(UInt64, x)
            @test atan(Bennett.SoftFloat(yb), Bennett.SoftFloat(xb)).bits ===
                  Bennett.soft_atan2(yb, xb)
        end
    end

    @testset "sin sugar wrapper extracts (VoidType wall regression)" begin
        # Pre-fix this threw "VoidType reached _type_width": with no
        # Base.sin(::SoftFloat) method, the wrapper compiled to a
        # jl_f_throw_methoderror + unreachable body with a void return.
        w = (x::UInt64) -> (@inline sin(Bennett.SoftFloat(x))).bits
        parsed = Bennett.extract_parsed_ir(w, Tuple{UInt64})
        @test parsed.ret_width == 64
        @test length(parsed.args) == 1 && parsed.args[1][2] == 64
        # soft_sin is @inline, so it may appear either as a registry-resolved
        # IRCall or fully inlined; either way the body must be non-trivial
        # (the pre-fix throw body had a single unreachable-terminated block).
        n_insts = sum(length(blk.instructions) for blk in parsed.blocks)
        @test n_insts > 10
    end

    @testset "reversible_compile(sin, Float64) end to end" begin
        c = reversible_compile(sin, Float64)
        @test verify_reversibility(c)
        for x in (1.0, 0.5, 0.78539816, 100.0)
            got = simulate(c, reinterpret(UInt64, x))
            actual = reinterpret(Float64, got)
            expected = sin(x)
            eb = reinterpret(UInt64, expected); ab = reinterpret(UInt64, actual)
            ulp = Int64(ab >= eb ? ab - eb : eb - ab)
            @test ulp <= 2
        end
    end
end
