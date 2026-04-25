# Bennett-9x75 / U61 — soft-float raw-bits fuzz across the full UInt64 input space.
#
# Existing fmul/fsub/fdiv/fma random sweeps draw from `randn() * 2^k` or
# `[-100, 100]`, which leave the subnormal, NaN, and extreme-exponent
# regions almost untested.  This is why the soft_exp [-708.4, -745]
# garbage bug (Bennett-wigl) and the soft_fdiv subnormal-divisor bug
# (Bennett-r6e3) survived their initial test campaigns.
#
# This file uses the canonical raw-bits template (template borrowed from
# test_softfdiv_subnormal.jl): `reinterpret(Float64, rand(rng, UInt64))`
# — every Float64 bit pattern equally likely.  For each op we assert
# bit-exact equality against the hardware reference across 5,000 inputs.
# All ops must produce zero failures (post Bennett-r84x NaN canonicalisation
# and Bennett-m63k fsub NaN-sign-flip fix).
#
# Cost: ~30,000 strict-bit assertions, ~2 s of test time.  Cheap enough
# to run unconditionally; expensive enough to catch regressions in any
# soft-float op's edge-case handling.

using Test
using Bennett
using Random

const _9X75_SEED = 0x9075
const _9X75_N    = 5_000   # per op

@testset "Bennett-9x75 / U61 — soft-float raw-bits fuzz across full UInt64" begin

    @testset "fadd raw-bits" begin
        rng = MersenneTwister(_9X75_SEED)
        fails = 0
        for _ in 1:_9X75_N
            a = reinterpret(Float64, rand(rng, UInt64))
            b = reinterpret(Float64, rand(rng, UInt64))
            got = soft_fadd(reinterpret(UInt64, a), reinterpret(UInt64, b))
            exp = reinterpret(UInt64, a + b)
            fails += (got != exp)
        end
        @test fails == 0
    end

    @testset "fsub raw-bits (regression for Bennett-m63k NaN-sign fix)" begin
        rng = MersenneTwister(_9X75_SEED)
        fails = 0
        for _ in 1:_9X75_N
            a = reinterpret(Float64, rand(rng, UInt64))
            b = reinterpret(Float64, rand(rng, UInt64))
            got = soft_fsub(reinterpret(UInt64, a), reinterpret(UInt64, b))
            exp = reinterpret(UInt64, a - b)
            fails += (got != exp)
        end
        @test fails == 0
    end

    @testset "fmul raw-bits" begin
        rng = MersenneTwister(_9X75_SEED)
        fails = 0
        for _ in 1:_9X75_N
            a = reinterpret(Float64, rand(rng, UInt64))
            b = reinterpret(Float64, rand(rng, UInt64))
            got = soft_fmul(reinterpret(UInt64, a), reinterpret(UInt64, b))
            exp = reinterpret(UInt64, a * b)
            fails += (got != exp)
        end
        @test fails == 0
    end

    @testset "fdiv raw-bits (regression for Bennett-r6e3)" begin
        rng = MersenneTwister(_9X75_SEED)
        fails = 0
        for _ in 1:_9X75_N
            a = reinterpret(Float64, rand(rng, UInt64))
            b = reinterpret(Float64, rand(rng, UInt64))
            got = soft_fdiv(reinterpret(UInt64, a), reinterpret(UInt64, b))
            exp = reinterpret(UInt64, a / b)
            fails += (got != exp)
        end
        @test fails == 0
    end

    @testset "fsqrt raw-bits (negatives produce INDEF per Bennett-r84x)" begin
        rng = MersenneTwister(_9X75_SEED)
        fails = 0
        for _ in 1:_9X75_N
            a = reinterpret(Float64, rand(rng, UInt64))
            got = soft_fsqrt(reinterpret(UInt64, a))
            # ccall to libm bypasses Julia's DomainError on sqrt(<0).
            hw  = reinterpret(UInt64, ccall(:sqrt, Cdouble, (Cdouble,), a))
            fails += (got != hw)
        end
        @test fails == 0
    end

    @testset "fma raw-bits" begin
        rng = MersenneTwister(_9X75_SEED)
        fails = 0
        for _ in 1:_9X75_N
            a = reinterpret(Float64, rand(rng, UInt64))
            b = reinterpret(Float64, rand(rng, UInt64))
            c = reinterpret(Float64, rand(rng, UInt64))
            got = soft_fma(reinterpret(UInt64, a),
                           reinterpret(UInt64, b),
                           reinterpret(UInt64, c))
            exp = reinterpret(UInt64, fma(a, b, c))
            fails += (got != exp)
        end
        @test fails == 0
    end
end
