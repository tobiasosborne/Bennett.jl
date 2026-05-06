# Bennett-7goc: soft_atan2 primitive contract tests.
#
# Bit/ULP coverage of the IEEE 754 binary64 two-argument arctangent
# `atan2(y, x)` on raw bit patterns. Faithful musl port (atan2.c) —
# branchless quadrant dispatch built on `soft_atan` from Bennett-qpke
# (CLAUDE.md §12 — no duplicated lowering: ratio is computed once via
# soft_fdiv and one soft_atan call). Target: ≤2 ULP vs `Base.atan(y,x)`
# across the full Float64 × Float64 input space.
#
# §13 (CLAUDE.md / Bennett-fnxg) — transcendental subnormal-output
# convention. `atan2(y, x)`'s range is `[-π, π]`; subnormal output occurs
# only when `|y/x|` is tiny AND quadrant is q0 or q1 (where the result
# tracks `±|y/x|` directly). The subnormal-binade sweep below covers
# this regime.

using Test
using Bennett

ulp_diff_atan2(got, exp) = let
    if isnan(exp); isnan(got) ? 0 : typemax(Int64)
    else
        gb = reinterpret(UInt64, got); eb = reinterpret(UInt64, exp)
        Int64(gb >= eb ? gb - eb : eb - gb)
    end
end

soft_atan2_f(y::Float64, x::Float64) =
    reinterpret(Float64, Bennett.soft_atan2(reinterpret(UInt64, y),
                                            reinterpret(UInt64, x)))

@testset "Bennett-7goc: soft_atan2 (musl atan2.c branchless)" begin

    @testset "smoke — all four quadrants, representative magnitudes" begin
        # q0 (x>0, y≥0), q1 (x>0, y<0), q2 (x<0, y≥0), q3 (x<0, y<0).
        for (y, x) in (
            ( 1.0,  1.0), ( 0.5,  0.5), ( 3.0,  4.0), ( 1e6,  1e6),
            ( 0.1,  100.0), ( 1.0, 1e-3),
            (-1.0,  1.0), (-0.5,  0.5), (-3.0,  4.0), (-1e10, 1.0),
            ( 1.0, -1.0), ( 0.5, -0.5), ( 3.0, -4.0), ( 1e6, -1e6),
            (-1.0, -1.0), (-0.5, -0.5), (-3.0, -4.0), (-1e6, -1e6),
        )
            got = soft_atan2_f(y, x)
            @test ulp_diff_atan2(got, atan(y, x)) <= 2
        end
    end

    @testset "axis points — y == 0 (any sign x)" begin
        # atan2(±0, +x) = ±0; atan2(±0, -x) = ±π. Bit-exact.
        for x in (1.0, 1e-10, 1e10, 100.0)
            @test soft_atan2_f( 0.0,  x) ===  0.0
            @test soft_atan2_f(-0.0,  x) === -0.0
            @test soft_atan2_f( 0.0, -x) ===  Float64(π)
            @test soft_atan2_f(-0.0, -x) === -Float64(π)
        end
    end

    @testset "axis points — x == 0 (any sign y)" begin
        # atan2(+y, ±0) = +π/2; atan2(-y, ±0) = -π/2. Bit-exact.
        for y in (1.0, 1e-10, 1e10, 100.0)
            @test soft_atan2_f( y,  0.0) ===  Float64(π/2)
            @test soft_atan2_f(-y,  0.0) === -Float64(π/2)
            @test soft_atan2_f( y, -0.0) ===  Float64(π/2)
            @test soft_atan2_f(-y, -0.0) === -Float64(π/2)
        end
    end

    @testset "specials — atan2(±0, ±0)" begin
        # atan2(+0, +0) = +0; atan2(-0, +0) = -0;
        # atan2(+0, -0) = +π; atan2(-0, -0) = -π.
        @test soft_atan2_f( 0.0,  0.0) ===  0.0
        @test soft_atan2_f(-0.0,  0.0) === -0.0
        @test soft_atan2_f( 0.0, -0.0) ===  Float64(π)
        @test soft_atan2_f(-0.0, -0.0) === -Float64(π)
    end

    @testset "specials — y == ±Inf, x finite" begin
        # atan2(±Inf, finite) = ±π/2.
        for x in (1.0, -1.0, 1e10, -1e10, 0.5, -0.5)
            @test soft_atan2_f( Inf, x) ===  Float64(π/2)
            @test soft_atan2_f(-Inf, x) === -Float64(π/2)
        end
    end

    @testset "specials — x == ±Inf, y finite (non-zero)" begin
        # atan2(±y, +Inf) = ±0; atan2(±y, -Inf) = ±π.
        for y in (1.0, 1e10, 1e-10)
            @test soft_atan2_f( y,  Inf) ===  0.0
            @test soft_atan2_f(-y,  Inf) === -0.0
            @test soft_atan2_f( y, -Inf) ===  Float64(π)
            @test soft_atan2_f(-y, -Inf) === -Float64(π)
        end
    end

    @testset "specials — both ±Inf" begin
        # atan2(+Inf, +Inf) = +π/4; atan2(-Inf, +Inf) = -π/4;
        # atan2(+Inf, -Inf) = +3π/4; atan2(-Inf, -Inf) = -3π/4.
        @test soft_atan2_f( Inf,  Inf) ===  Float64(π/4)
        @test soft_atan2_f(-Inf,  Inf) === -Float64(π/4)
        @test soft_atan2_f( Inf, -Inf) ===  Float64(3π/4)
        @test soft_atan2_f(-Inf, -Inf) === -Float64(3π/4)
    end

    @testset "NaN propagation" begin
        # If either operand is NaN, result is NaN (with quiet bit set).
        @test isnan(soft_atan2_f(NaN, 1.0))
        @test isnan(soft_atan2_f(1.0, NaN))
        @test isnan(soft_atan2_f(NaN, NaN))
        @test isnan(soft_atan2_f(NaN, Inf))
        @test isnan(soft_atan2_f(Inf, NaN))
        @test isnan(soft_atan2_f(NaN, 0.0))
        @test isnan(soft_atan2_f(0.0, NaN))
    end

    @testset "magnitude span — y/x huge (saturates at ±π/2)" begin
        # |y/x| >> 1 → result ≈ ±π/2. soft_atan(huge_ratio) returns
        # ±π/2 via its huge-arg fast path; quadrant offset adds π or 0.
        for (y, x) in ((1e300, 1.0), (1e300, -1.0), (1.0, 1e-300), (1.0, -1e-300))
            got = soft_atan2_f(y, x)
            @test ulp_diff_atan2(got, atan(y, x)) <= 2
        end
    end

    @testset "magnitude span — y/x tiny (preserves ratio sign)" begin
        # |y/x| << 1 → result tracks ±|y/x| in q0/q1, ≈ ±π in q2/q3.
        for (y, x) in ((1.0, 1e300), (-1.0, 1e300), (1.0, -1e300), (-1.0, -1e300))
            got = soft_atan2_f(y, x)
            @test ulp_diff_atan2(got, atan(y, x)) <= 2
        end
    end

    @testset "subnormal-output sweep (§13 / Bennett-fnxg)" begin
        # Subnormal `atan2(y, x)` output occurs in q0/q1 when |y/x| is
        # tiny enough that `atan(|y/x|) ≈ |y/x|` falls into the
        # subnormal regime. Sweep |y|/|x| binades 2^-1075..2^-50 by
        # fixing x = 1.0 and stepping y down.
        max_ulp = Int64(0)
        n_subnormal = 0
        for binade in -1075:-50
            y = 2.0^Float64(binade)
            x = 1.0
            got = soft_atan2_f(y, x)
            expected = atan(y, x)
            issubnormal(expected) && (n_subnormal += 1)
            max_ulp = max(max_ulp, ulp_diff_atan2(got, expected))
        end
        @test max_ulp <= 1
        @test n_subnormal > 0   # confirm sweep actually visits subnormals
    end

    @testset "quadrant boundaries — sign-flip continuity" begin
        # Across each axis the quadrant changes; verify continuity.
        for r in (0.5, 1.0, 1.5, 100.0)
            # +y axis crossing (x: +ε → -ε, y > 0). Result jumps π/2 → π.
            for ε in (1e-300, 1e-100, 1e-10, 1e-3)
                @test ulp_diff_atan2(soft_atan2_f(r,  ε), atan(r,  ε)) <= 2
                @test ulp_diff_atan2(soft_atan2_f(r, -ε), atan(r, -ε)) <= 2
            end
        end
    end

    @testset "100k random sweep, 3 seeds, 4 magnitude buckets × 4 quadrants" begin
        using Random
        for seed in (UInt(0xCAFEBABE), UInt(0xDEADBEEF), UInt(0x4A2A4E32))
            Random.seed!(seed)
            n_per_seed = 100_000 ÷ 3
            atan2_max = Int64(0); atan2_fail = 0
            for _ in 1:n_per_seed
                # 4 magnitude buckets cover small/medium/huge ratios.
                mag = rand(1:4)
                ymag = if mag == 1; 1e-3
                       elseif mag == 2; 1.0
                       elseif mag == 3; 1e3
                       else;            1e10
                       end
                xmag = if mag == 1; 1.0
                       elseif mag == 2; 1.0
                       elseif mag == 3; 1.0
                       else;            1e-5
                       end
                # Random quadrant via independent sign on each.
                y = (rand() - 0.5) * 2 * ymag
                x = (rand() - 0.5) * 2 * xmag
                got = soft_atan2_f(y, x)
                u = ulp_diff_atan2(got, atan(y, x))
                atan2_max = max(atan2_max, u); u > 2 && (atan2_fail += 1)
            end
            @test atan2_fail == 0
            @test atan2_max <= 2
        end
    end

    @testset "callee registered" begin
        @test Bennett._lookup_callee("soft_atan2") === Bennett.soft_atan2
    end

end
