using Test
using Bennett
using Bennett: soft_pow

# Bennett-iys2: soft_pow(-1, y) returned +1.0 for EVERY y — the Tier-0
# override `pow(±1, y) = 1` was keyed on |x| == 1, but C99/POSIX only make
# that unconditional for x = +1. For x = -1 the rules are:
#   pow(-1, ±Inf)       = +1
#   pow(-1, even int y) = +1     pow(-1, odd int y) = -1
#   pow(-1, non-int y)  = NaN    pow(-1, NaN)       = NaN
# (pow(x, ±0) = 1 still wins for every x.) Reachable via `llvm.pow.f64`
# ingest (C / Rust / .ll); Julia's `^` lowers to soft_pow_julia instead.
#
# Reference: Base.:^ where it is defined; it throws DomainError for a
# negative base with a non-integer exponent, where libm returns NaN.

_iys2_ref(x::Float64, y::Float64) = try x^y catch; NaN end
_iys2_pow(x::Float64, y::Float64) =
    reinterpret(Float64, soft_pow(reinterpret(UInt64, x), reinterpret(UInt64, y)))
_iys2_same(a::Float64, b::Float64) = isnan(b) ? isnan(a) : a === b

# Exponents covering odd / even integers (small, 2^53-1, 2^53, 2^63, floatmax),
# non-integers (0.5, subnormal, 2^-70 — the |y| < 2^-65 "y_special" band),
# ±Inf, NaN and ±0.
const _IYS2_YS = Float64[
    1.0, -1.0, 2.0, -2.0, 3.0, -3.0, 4.0, 101.0, -101.0, 1000.0,
    2.0^52 + 1, 2.0^53 - 1, -(2.0^53 - 1), 2.0^53, 2.0^63, -2.0^63, 1e300, -1e300,
    floatmax(Float64), -floatmax(Float64),
    0.5, -0.5, 1.5, -2.5, 1e-10, 2.0^-70, -2.0^-70, nextfloat(0.0), -nextfloat(0.0),
    nextfloat(3.0), prevfloat(2.0^53),
    Inf, -Inf, NaN, 0.0, -0.0,
]

@testset "Bennett-iys2: soft_pow(-1, y) follows the libm sign / NaN rules" begin
    @testset "pow(-1, y) bit-exact vs Base.:^" begin
        for y in _IYS2_YS
            got = _iys2_pow(-1.0, y)
            exp = _iys2_ref(-1.0, y)
            ok = _iys2_same(got, exp)
            ok || @warn "soft_pow(-1, y) mismatch" y got exp
            @test ok
        end
    end

    @testset "pow(+1, y) = 1 for every y (unchanged)" begin
        for y in _IYS2_YS
            @test _iys2_pow(1.0, y) === 1.0
        end
    end

    @testset "witness values from the bead" begin
        @test _iys2_pow(-1.0, 1.0)  === -1.0
        @test _iys2_pow(-1.0, 3.0)  === -1.0
        @test _iys2_pow(-1.0, -3.0) === -1.0
        @test isnan(_iys2_pow(-1.0, 0.5))
        @test isnan(_iys2_pow(-1.0, NaN))
        @test _iys2_pow(-1.0, 2.0)  === 1.0
        @test _iys2_pow(-1.0, Inf)  === 1.0
        @test _iys2_pow(-1.0, -Inf) === 1.0
    end

    # Other negative bases were already right; pin the sign rule so the
    # x = -1 fix cannot regress them (≤2 ULP is soft_pow's documented contract).
    @testset "negative base, integer / non-integer y (≤2 ULP, sign exact)" begin
        for x in (-2.0, -1.5, -0.75, -3.0, -10.0, -nextfloat(1.0), -prevfloat(1.0)),
            y in (1.0, 2.0, 3.0, -3.0, -4.0, 7.0, 0.5, -1.5, 2.5)
            got = _iys2_pow(x, y)
            exp = _iys2_ref(x, y)
            if isnan(exp)
                @test isnan(got)
            else
                @test signbit(got) == signbit(exp)
                @test abs(reinterpret(Int64, got) - reinterpret(Int64, exp)) <= 2
            end
        end
    end

    # Compiled-circuit path: the llvm.pow.f64 .ll fixture is exactly the
    # ingest route the bead names.
    @testset "llvm.pow.f64 circuit: pow(-1, y)" begin
        path = joinpath(@__DIR__, "fixtures", "ll", "emv_pow_f64.ll")
        c = reversible_compile(Bennett.extract_parsed_ir_from_ll(path; entry_function="pow_f64"))
        @test verify_reversibility(c)
        call(x, y) = reinterpret(Float64, UInt64(simulate(c,
                         (reinterpret(UInt64, x), reinterpret(UInt64, y)))))
        for y in (1.0, 3.0, -3.0, 2.0, -4.0, 0.5, NaN, Inf, -Inf, 0.0, 2.0^53 - 1)
            @test _iys2_same(call(-1.0, y), _iys2_ref(-1.0, y))
            @test call(1.0, y) === 1.0
        end
    end
end
