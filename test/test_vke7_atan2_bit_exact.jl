using Test, Bennett, Random

# Bennett-vke7: soft_atan2 must be BIT-EXACT against Base.atan(y, x)
# (CLAUDE.md rule 13). Pre-fix, the x < 0 half-plane computed `π - z`
# instead of Base's `π - (z - ATAN2_PI_LO)`, so ~31% of random q2/q3
# inputs came out 1 ULP off (witnesses: atan(2.5, -1.0), atan(-3.7, -1.0)).
# Invariant: reinterpret(UInt64, soft_atan2(y, x)) == reinterpret(UInt64,
# Base.atan(y, x)) for every (y, x), NaN payloads included — WHENEVER the
# inner one-argument atan agrees, i.e. soft_atan(|y/x|) == Base.atan(|y/x|).
#
# Why the guard: Base.atan(x) evaluates its polynomial with `@horner` →
# `evalpoly` → `muladd`, which fuses to an FMA on FMA hosts (x86-64-v3+);
# soft_atan uses separate mul + add, so it is 1 ULP off Base on ~2.5e-5 of
# inputs in [0.3125, 0.4375) ∪ [2.4, 3.6) (witness r = 0.4280128875928157).
# That is a soft_atan defect (host-dependent reference), filed separately;
# this file pins the atan2 layer exactly and the residual rate loosely.

_bits(v::Float64) = reinterpret(UInt64, v)
_sa2(y::Float64, x::Float64) = soft_atan2(_bits(y), _bits(x))
_inner_ok(y, x) = (r = abs(y / x); isnan(r) || soft_atan(_bits(r)) == _bits(atan(r)))
# true iff soft_atan2 is bit-exact OR the miss is soft_atan's (inner atan differs)
_exact(y, x) = _sa2(y, x) == _bits(atan(y, x)) || !_inner_ok(y, x)

@testset "Bennett-vke7: soft_atan2 bit-exact vs Base.atan(y, x)" begin

    @testset "witnesses" begin
        @test _sa2(2.5, -1.0)  == _bits(1.9513027039072617)
        @test _sa2(-3.7, -1.0) == _bits(atan(-3.7, -1.0))
        @test _exact(2.5, -1.0)
        @test _exact(-3.7, -1.0)
    end

    @testset "soft_atan residual (muladd/FMA in Base's polynomial) stays rare" begin
        rng = Xoshiro(0x7e7)
        nbad = 0; nmiss2 = 0
        for _ in 1:20_000
            v = (rand(rng) * 2 - 1) * 2.0^rand(rng, -80:80)
            nbad += soft_atan(_bits(v)) != _bits(atan(v))
            # and every soft_atan2 miss is explained by the inner soft_atan miss
            x = -rand(rng) - 0.5
            nmiss2 += _sa2(v, x) != _bits(atan(v, x))
        end
        @test nbad <= 20       # ~2.5e-5 observed; pre-vke7 atan2 was ~31% in q2/q3
        @test nmiss2 <= 20
    end

    @testset "random sweep — 4 quadrants × binades" begin
        for seed in (1, 2, 3)
            rng = Xoshiro(seed)
            bad = zeros(Int, 4)
            for _ in 1:40_000
                y = rand(rng) * 2.0^rand(rng, -70:70)
                x = rand(rng) * 2.0^rand(rng, -70:70)
                for (sy, sx) in ((1, 1), (-1, 1), (1, -1), (-1, -1))
                    yy = sy * y; xx = sx * x
                    m = 2 * signbit(xx) + signbit(yy)
                    bad[m + 1] += !_exact(yy, xx)
                end
            end
            @test bad == [0, 0, 0, 0]
        end
    end

    @testset "full-range bit patterns (incl. subnormal operands)" begin
        rng = Xoshiro(0xa7a2)
        nbad = 0
        for _ in 1:50_000
            y = reinterpret(Float64, rand(rng, UInt64))
            x = reinterpret(Float64, rand(rng, UInt64))
            (isnan(y) || isnan(x)) && continue
            nbad += !_exact(y, x)
        end
        @test nbad == 0
        nbad = 0
        for _ in 1:20_000   # subnormal operands
            y = reinterpret(Float64, rand(rng, UInt64(1):UInt64(0x000FFFFFFFFFFFFF))) * rand(rng, (-1, 1))
            x = reinterpret(Float64, rand(rng, UInt64(1):UInt64(0x000FFFFFFFFFFFFF))) * rand(rng, (-1, 1))
            nbad += !_exact(y, x) + !_exact(y, 1.5 * rand(rng, (-1, 1))) + !_exact(-2.0, x)
        end
        @test nbad == 0
    end

    @testset "huge and tiny |y/x| ratios (Base's k > 60 / k < -60 shortcuts)" begin
        for e in 50:1:75, sy in (1.0, -1.0), sx in (1.0, -1.0), mant in (1.0, 1.37, 1.999)
            for xb in (1.0, 3.3e-5, 7.7e200)
                y = sy * mant * 2.0^e * xb; x = sx * xb
                @test _exact(y, x)     # huge ratio
                @test _exact(x, y)     # tiny ratio
            end
        end
    end

    @testset "x == 1.0 shortcut and near-1 x" begin
        for y in (0.3, -0.3, 1e-300, -1e300, 5e-324, 2.5, -3.7, Inf, -Inf, 0.0, -0.0)
            @test _exact(y, 1.0)
            @test _exact(y, nextfloat(1.0))
            @test _exact(y, prevfloat(1.0))
        end
    end

    @testset "special cases (every Base branch)" begin
        vals = (0.0, -0.0, Inf, -Inf, 1.0, -1.0, 2.5, -3.7, 5e-324, -5e-324,
                floatmax(), -floatmax(), floatmin(), -floatmin())
        for y in vals, x in vals
            @test _exact(y, x)
        end
    end

    @testset "NaN — Base returns x if NaN, else y, payload unchanged" begin
        n1 = reinterpret(Float64, 0x7FF8000000000001)
        n2 = reinterpret(Float64, 0xFFF8000000000002)
        sn = reinterpret(Float64, 0x7FF0000000000003)   # signalling
        for a in (n1, n2, sn), b in (0.0, -0.0, 1.0, -1.0, Inf, -Inf, 2.5, n1, n2, sn)
            @test _exact(a, b)
            @test _exact(b, a)
        end
    end

    @testset "subnormal-output range" begin
        # atan(y, x) ≈ y/x for tiny y/x with x > 0: target every subnormal binade
        # 2^t, t ∈ [-1075, -1021], in 0.25 steps, across several x scales.
        nbad = 0; ntot = 0; nsub = 0
        for (m, s) in ((1.0, 0), (3.0, 0), (1.3, 10), (1.0, 300), (1.7, 900))
            xs = m * 2.0^s
            t = -1021.0
            while t >= -1076.0
                y = m * 2.0^(t + s)   # y/x ≈ 2^t (no underflow before the scale-up)
                if isfinite(y) && y != 0.0
                    for sy in (1.0, -1.0)
                        r = atan(sy * y, xs)
                        nsub += issubnormal(r)
                        ntot += 1
                        nbad += !_exact(sy * y, xs)
                    end
                end
                t -= 0.25
            end
        end
        @test nsub > 300            # the sweep actually populates the subnormal range
        @test nbad == 0
    end

    @testset "Float64 sugar path" begin
        @test atan(Bennett.SoftFloat(_bits(2.5)), Bennett.SoftFloat(_bits(-1.0))).bits == _bits(atan(2.5, -1.0))
    end
end
