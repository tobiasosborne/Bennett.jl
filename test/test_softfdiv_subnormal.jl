using Test
using Bennett
using Bennett: soft_fdiv
using Random

# Bennett-r6e3: soft_fdiv subnormal handling. 59/200k random raw-bit failures
# all involve a subnormal input. Root cause (to be fixed): fdiv does NOT
# pre-normalize subnormal ma/mb before the 56-bit restoring-division loop, so
# the quotient is either overflow (subnormal divisor → true ratio doesn't fit
# in 56 bits) or has insufficient precision.
#
# RED before fix: these testsets expose the bug.
# GREEN after fix: MersenneTwister(12345) raw-bits sweep = 0 failures.

@testset "soft_fdiv: MersenneTwister(12345) 200k raw-bits sweep (Bennett-r6e3)" begin
    rng = MersenneTwister(12345)
    failures = 0
    n_checked = 0
    for _ in 1:200_000
        a = reinterpret(Float64, rand(rng, UInt64))
        b = reinterpret(Float64, rand(rng, UInt64))
        (isfinite(a) && isfinite(b) && !iszero(b)) || continue
        n_checked += 1
        ra = soft_fdiv(reinterpret(UInt64, a), reinterpret(UInt64, b))
        ea = reinterpret(UInt64, a / b)
        failures += (ra != ea)
    end
    # After fix, failures == 0.
    @test failures == 0
end

@testset "soft_fdiv: specific subnormal-divisor cases from bd notes" begin
    # Failure cases recorded on Bennett-r6e3 on 2026-04-13.
    for (a, b) in [
        (8.22e-230,  -2.09e-308),   # huge-delta (reported as -3.71e78 vs -3.94e78)
        (3.96e-290,  -1.12e-308),   # huge-delta (reported as -2.31e18 vs -3.54e18)
    ]
        ra = soft_fdiv(reinterpret(UInt64, a), reinterpret(UInt64, b))
        ea = reinterpret(UInt64, a / b)
        @test ra == ea
    end
end

@testset "soft_fdiv: subnormal quotient 1-ULP case" begin
    # Third reported failure: subnormal dividend + normal divisor.
    a = 2.49e-309
    b = 6.57e-221
    ra = soft_fdiv(reinterpret(UInt64, a), reinterpret(UInt64, b))
    ea = reinterpret(UInt64, a / b)
    @test ra == ea
end

@testset "soft_fdiv: smallest-subnormal / 1.0 = smallest-subnormal" begin
    # Smoke test known-good case (likely already passes even pre-fix).
    a = reinterpret(Float64, UInt64(1))   # 5e-324, smallest positive subnormal
    b = 1.0
    ra = soft_fdiv(reinterpret(UInt64, a), reinterpret(UInt64, b))
    ea = reinterpret(UInt64, a / b)
    @test ra == ea
end

@testset "soft_fdiv: 1.0 / smallest-subnormal" begin
    # Expected: 1 / 5e-324 = +Inf (overflow). Currently likely fails due to
    # divisor subnormal → division-loop overflow → wrong answer.
    a = 1.0
    b = reinterpret(Float64, UInt64(1))
    ra = soft_fdiv(reinterpret(UInt64, a), reinterpret(UInt64, b))
    ea = reinterpret(UInt64, a / b)
    @test ra == ea
end

@testset "soft_fdiv: subnormal / subnormal = normal" begin
    # Both subnormal; quotient should be a normal value.
    a = reinterpret(Float64, UInt64(0x0008000000000000))   # ~1.1e-308
    b = reinterpret(Float64, UInt64(0x0004000000000000))   # ~5.6e-309
    ra = soft_fdiv(reinterpret(UInt64, a), reinterpret(UInt64, b))
    ea = reinterpret(UInt64, a / b)
    @test ra == ea
end

@testset "soft_fdiv: pre-fix normals-only sweep still passes" begin
    # Regression guard: normals-only sweep was 0 failures pre-fix. Must stay 0.
    rng = MersenneTwister(98765)
    failures = 0
    for _ in 1:5_000
        a = (rand(rng) - 0.5) * 1e6
        b = (rand(rng) - 0.5) * 1e6
        iszero(b) && continue
        ra = soft_fdiv(reinterpret(UInt64, a), reinterpret(UInt64, b))
        ea = reinterpret(UInt64, a / b)
        failures += (ra != ea)
    end
    @test failures == 0
end
