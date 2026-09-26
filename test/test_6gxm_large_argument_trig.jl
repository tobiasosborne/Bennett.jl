# Bennett-6gxm: Payne-Hanek INV_2PI table limb 12 typo.
#
# `_RP_INV_2PI[12]` in src/softfloat/fsin.jl was `0xc7fe25ffff781660`
# (a one-nibble transcription slip) instead of `0xc7fe25fff7816603`.
# Limb 12 is only consumed by the Payne-Hanek reduction for unbiased
# exponents ≈ 682..819, so soft_sin / soft_cos / soft_tan returned
# unrelated values (incl. sign flips) for |x| ∈ [2^682, 2^820), while every
# pre-existing test capped its arguments at ~1e22 ≈ 2^73.
#
# Guards:
#   (a) every limb of the table equals BOTH `Base.Math.INV_2PI` (same
#       19 × UInt64 layout) and an independent 4096-bit BigFloat expansion
#       of 1/(2π);
#   (b) a large-argument binade sweep e ∈ 60:1023, fixed + seeded-random
#       significands, both signs, against Base.sin/cos/tan at the
#       documented ≤2 ULP contract (fsin.jl / ftan.jl docstrings).

using Test
using Random
using Bennett

# Sign-aware ordinal ULP distance on Float64 bit patterns (a sign flip is a
# huge distance, not a small unsigned difference).
function _ulp_6gxm(got::Float64, ref::Float64)
    isnan(ref) && return isnan(got) ? 0 : typemax(Int64)
    isnan(got) && return typemax(Int64)
    ord(x) = (b = reinterpret(Int64, x); b < 0 ? typemin(Int64) - b : b)
    d = widen(ord(got)) - widen(ord(ref))
    return Int64(min(abs(d), widen(typemax(Int64))))
end

@testset "Bennett-6gxm: Payne-Hanek INV_2PI table + large-argument trig" begin

    @testset "INV_2PI table matches Base and 4096-bit BigFloat" begin
        T = Bennett.SoftFloatLib._RP_INV_2PI
        @test length(T) == 19
        @test length(Base.Math.INV_2PI) == 19
        # Independent value: 1/(2π) at 4096 bits, peeled into 64-bit limbs.
        limbs = setprecision(BigFloat, 4096) do
            r = inv(2 * big(π))
            out = UInt64[]
            for _ in 1:19
                r *= big(2)^64
                l = floor(r)
                push!(out, UInt64(l))
                r -= l
            end
            out
        end
        for k in 1:19
            @test T[k] == Base.Math.INV_2PI[k]
            @test T[k] == limbs[k]
        end
        # The specific limb that was wrong.
        @test T[12] == 0xc7fe25fff7816603
    end

    @testset "report witnesses (formerly sign flips)" begin
        for (f, sf, bits) in ((sin, Bennett.soft_sin, 0x6dfd3af758367500),
                              (cos, Bennett.soft_cos, 0x7096a3fc1ff6c559),
                              (tan, Bennett.soft_tan, 0x72e7a7b800919a08))
            x = reinterpret(Float64, bits)
            got = reinterpret(Float64, sf(bits))
            @test _ulp_6gxm(got, f(x)) <= 2
            @test signbit(got) == signbit(f(x))
        end
    end

    @testset "binade sweep e ∈ 60:1023 (≤2 ULP)" begin
        rng = MersenneTwister(0x6a0c)
        fixed = (1.0, 1.25, 1.5, 1.9)
        nbad = Dict(:sin => 0, :cos => 0, :tan => 0)
        maxu = Dict(:sin => 0, :cos => 0, :tan => 0)
        for e in 60:1023
            sigs = (fixed..., (1.0 + rand(rng) for _ in 1:4)...)
            for m in sigs, s in (1.0, -1.0)
                x = s * ldexp(m, e)
                isfinite(x) || continue
                xb = reinterpret(UInt64, x)
                for (name, f, sf) in ((:sin, sin, Bennett.soft_sin),
                                      (:cos, cos, Bennett.soft_cos),
                                      (:tan, tan, Bennett.soft_tan))
                    u = _ulp_6gxm(reinterpret(Float64, sf(xb)), f(x))
                    maxu[name] = max(maxu[name], u)
                    u <= 2 || (nbad[name] += 1)
                end
            end
        end
        @info "Bennett-6gxm large-arg sweep" max_ulp = maxu
        @test nbad[:sin] == 0
        @test nbad[:cos] == 0
        @test nbad[:tan] == 0
    end
end
