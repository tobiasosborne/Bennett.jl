@testset "Bennett-ys0d / U134 — soft_exp accuracy contract" begin

    # ---- Investigation summary (Bennett-ys0d / U134, 2026-04-27) ----
    #
    # `soft_exp` (musl-derived) is bit-exact vs musl's `exp.c` and ≤1 ULP
    # vs `Base.exp`. Its sibling `soft_exp_julia` (Julia-idiom variant) is
    # bit-exact vs `Base.exp`. The review (reviews/2026-04-21/11_softfloat.md
    # F6) flagged this as a discoverability bug: users who pick `soft_exp`
    # as the default get ~0.9% off-by-1-ULP results vs `Base.exp`, despite
    # a sibling existing with no such gap.
    #
    # Disposition: docstring update + this contract test. The user-facing
    # default IS already correct: `Base.exp(x::SoftFloat) = soft_exp_julia(x.bits)`
    # (src/Bennett.jl:413). So Julia code calling `Base.exp` on a SoftFloat
    # gets bit-exact for free. The bead is about `soft_exp` being misnamed
    # as "the canonical exp" when it's really "the musl-bit-exact variant".
    #
    # This test pins:
    # 1. soft_exp_julia is 0% off vs Base.exp on a 50k random sample.
    # 2. soft_exp is < 2% off (with empirical baseline ~0.9%) — pinned as
    #    a regression guard against accidental degradation.
    # 3. Base.exp(x::SoftFloat) routes to soft_exp_julia (so users get
    #    bit-exact by default).
    # 4. Same for soft_exp2 / soft_exp2_julia / Base.exp2.

    bits(x::Float64) = reinterpret(UInt64, x)

    function _disagreement_rate(soft_op::F, base_op::G,
                                 n_iters::Int, range::Tuple{Float64, Float64}) where {F, G}
        n_diff = 0
        for _ in 1:n_iters
            x = range[1] + (range[2] - range[1]) * rand()
            base_r = bits(base_op(x))
            soft_r = soft_op(bits(x))
            n_diff += (base_r != soft_r)
        end
        return n_diff / n_iters
    end

    @testset "soft_exp_julia is bit-exact vs Base.exp" begin
        rate = _disagreement_rate(Bennett.soft_exp_julia, exp, 50_000, (-30.0, 30.0))
        @test rate == 0.0
    end

    @testset "soft_exp is at most ~2% off vs Base.exp (empirical baseline ~0.9%)" begin
        rate = _disagreement_rate(Bennett.soft_exp, exp, 50_000, (-30.0, 30.0))
        @test rate < 0.02      # generous upper bound — empirical 2026-04-27 = 0.91%
        @test rate > 0.001     # below this would suggest soft_exp accidentally became bit-exact
                                # — file a follow-up to investigate
    end

    @testset "soft_exp2_julia is bit-exact vs Base.exp2" begin
        rate = _disagreement_rate(Bennett.soft_exp2_julia, exp2, 50_000, (-300.0, 300.0))
        @test rate == 0.0
    end

    @testset "Base.exp(::SoftFloat) routes to soft_exp_julia (bit-exact)" begin
        # Sanity: any SoftFloat input → Base.exp produces same bits as
        # the bit-exact soft_exp_julia. The routing in Bennett.jl:413 is
        # the user-facing guarantee.
        for x in (0.0, 1.0, -1.0, 0.5, -0.5, 5.7, -5.7, 100.0, -100.0,
                   ldexp(1.0, -10), ldexp(1.0, 10))
            sf_x = Bennett.SoftFloat(x)
            @test Bennett.soft_exp_julia(bits(x)) == Base.exp(sf_x).bits
        end
    end

    @testset "Base.exp2(::SoftFloat) routes to soft_exp2_julia (bit-exact)" begin
        for x in (0.0, 1.0, -1.0, 0.5, -0.5, 10.0, -10.0, 50.0, -50.0)
            sf_x = Bennett.SoftFloat(x)
            @test Bennett.soft_exp2_julia(bits(x)) == Base.exp2(sf_x).bits
        end
    end
end
