using Test
using Bennett
using Bennett: soft_pow_julia
using Random

# Bennett.jl soft_pow_julia — bit-exact vs Base.:^(::Float64, ::Float64)
# on FMA-capable hardware. Path A of Bennett-jexo: line-for-line port of
# Julia's `^(::Float64, ::Float64)` (with `pow_body` for both float and
# integer y, `_log_ext` 128-entry table + degree-6 polynomial, and the
# extended `exp_impl(x, xlo, Val(:ℯ))` 256-entry kernel) with every
# `muladd` replaced by either `soft_fma` or `soft_fadd∘soft_fmul`
# depending on whether Julia contracts at that site (verified via
# `@code_llvm`). See header of `src/softfloat/fpow_julia.jl` for the
# full algorithmic reference.

# Julia's Base.:^ throws DomainError for negative-x non-integer-y;
# soft_pow_julia returns NaN per IEEE 754 (no exceptions in branchless
# soft float). The test wrapper catches DomainError and reports NaN so
# the bit-exact comparison treats {NaN soft, NaN safe} as equal.
function _pow_safe(x::Float64, y::Float64)::Float64
    try return x^y catch; return NaN end
end

bits(x::Float64) = reinterpret(UInt64, x)

@testset "soft_pow_julia library" begin

    function check_pow(x::Float64, y::Float64)
        a_bits   = soft_pow_julia(bits(x), bits(y))
        expected = _pow_safe(x, y)
        e_bits   = bits(expected)
        a_f      = reinterpret(Float64, a_bits)
        if isnan(expected)
            @test isnan(a_f)
        else
            @test a_bits == e_bits
        end
    end

    @testset "smoke (integer powers, exact)" begin
        check_pow(2.0, 3.0)         # 8.0
        check_pow(3.0, 4.0)         # 81.0
        check_pow(10.0, 2.0)        # 100.0
        check_pow(2.0, 0.5)         # √2
        check_pow(1.0, 100.0)       # 1
        check_pow(5.0, 0.0)         # 1
        check_pow(1.5, 2.5)
        check_pow(3.14159, 2.71828)
        check_pow(-2.0, 3.0)        # -8 (negative x, odd-int y)
        check_pow(-2.0, 4.0)        # 16 (negative x, even-int y)
        check_pow(-3.0, -3.0)       # -1/27 (negative x, odd-int negative y)
    end

    # ── Special cases per IEEE 754-2019 §9.2 / POSIX ──────────────────

    @testset "pow(x, ±0) = 1.0 (always, even pow(NaN, 0))" begin
        for x in (1.0, 2.0, -3.5, 0.0, -0.0, Inf, -Inf, NaN)
            @test soft_pow_julia(bits(x), bits(0.0))  == bits(1.0)
            @test soft_pow_julia(bits(x), bits(-0.0)) == bits(1.0)
        end
    end

    @testset "pow(±1, y) = 1.0 (always)" begin
        for y in (0.0, 1.0, -1.0, 0.5, 100.0, -100.0, Inf, -Inf, NaN)
            @test soft_pow_julia(bits(1.0),  bits(y)) == bits(1.0)
            # Note: pow(-1, y) for non-int y throws DomainError in Julia;
            # Julia's source returns 1.0 only for y=±0 in this case (via
            # the `yint == 0 && return 1.0` early-out). Our soft port
            # mirrors this: pow(-1, NaN) returns NaN, pow(-1, 0.5) NaN,
            # pow(-1, integer) returns ±1.
            if y isa Float64 && (y == round(y)) && isfinite(y)
                expected = isodd(Int64(y)) ? bits(-1.0) : bits(1.0)
                @test soft_pow_julia(bits(-1.0), bits(y)) == expected
            end
        end
    end

    @testset "pow(NaN, y≠0) = NaN" begin
        for y in (1.0, 0.5, -1.0, Inf, -Inf, 2.5, -3.0)
            @test isnan(reinterpret(Float64, soft_pow_julia(bits(NaN), bits(y))))
        end
    end

    @testset "pow(x, NaN) = NaN" begin
        for x in (2.0, 0.5, -1.5, Inf, -Inf, 0.0, -0.0)
            @test isnan(reinterpret(Float64, soft_pow_julia(bits(x), bits(NaN))))
        end
    end

    @testset "pow(±0, y<0) = ±Inf (sign rule for odd-int y)" begin
        @test soft_pow_julia(bits( 0.0), bits(-3.0)) == bits( Inf)
        @test soft_pow_julia(bits(-0.0), bits(-3.0)) == bits(-Inf)
        @test soft_pow_julia(bits( 0.0), bits(-2.0)) == bits( Inf)
        @test soft_pow_julia(bits(-0.0), bits(-2.0)) == bits( Inf)
        @test soft_pow_julia(bits( 0.0), bits(-2.5)) == bits( Inf)
    end

    @testset "pow(±0, y>0) = ±0 (sign rule for odd-int y)" begin
        @test soft_pow_julia(bits( 0.0), bits(3.0)) == bits( 0.0)
        @test soft_pow_julia(bits(-0.0), bits(3.0)) == bits(-0.0)
        @test soft_pow_julia(bits( 0.0), bits(2.0)) == bits( 0.0)
        @test soft_pow_julia(bits(-0.0), bits(2.0)) == bits( 0.0)
        @test soft_pow_julia(bits( 0.0), bits(0.5)) == bits( 0.0)
    end

    @testset "pow(|x|<1, ±Inf) → +0 / +Inf" begin
        for x in (0.5, -0.5, 0.99, -0.99)
            @test soft_pow_julia(bits(x), bits( Inf)) == bits(0.0)
            @test soft_pow_julia(bits(x), bits(-Inf)) == bits(Inf)
        end
    end

    @testset "pow(|x|>1, ±Inf) → +Inf / +0" begin
        for x in (2.0, -2.0, 100.0, -100.0)
            @test soft_pow_julia(bits(x), bits( Inf)) == bits(Inf)
            @test soft_pow_julia(bits(x), bits(-Inf)) == bits(0.0)
        end
    end

    @testset "pow(+Inf, y) = +Inf for y>0; +0 for y<0" begin
        @test soft_pow_julia(bits(Inf), bits( 2.0)) == bits(Inf)
        @test soft_pow_julia(bits(Inf), bits( 0.5)) == bits(Inf)
        @test soft_pow_julia(bits(Inf), bits(-2.0)) == bits(0.0)
        @test soft_pow_julia(bits(Inf), bits(-0.5)) == bits(0.0)
    end

    @testset "pow(-Inf, y) — match Base.^ exactly" begin
        # Note: Julia's `^(-Inf, n_int)` with n_int in `use_power_by_squaring`
        # range routes through the integer `pow_body`, which does NOT apply
        # the IEEE odd-integer sign rule. Instead it computes
        # `1/(-Inf) = -0.0`, then squares: `(-0.0)^|n| = ±0` per the squaring
        # algorithm. For n=-3 (odd), the algorithm produces +0.0 (verified
        # via `Base.Math.pow_body(-Inf, -3)`), NOT -0.0 as the IEEE rule
        # would suggest. We mirror Julia bit-exactly.
        check_pow(-Inf,  3.0)   # → -Inf  (integer body: x*x*x = -Inf)
        check_pow(-Inf, -3.0)   # → +0.0  (integer body, NOT IEEE -0)
        check_pow(-Inf,  2.0)   # → +Inf
        check_pow(-Inf, -2.0)   # → +0.0
    end

    @testset "pow(x<0, non-int y) = NaN" begin
        for (x, y) in [(-2.0, 0.5), (-3.0, 1.5), (-1.5, 2.5), (-100.0, 0.1)]
            @test isnan(reinterpret(Float64, soft_pow_julia(bits(x), bits(y))))
        end
    end

    @testset "negative x × small integer y (sign rule, bit-exact)" begin
        for x in (-2.0, -3.0, -1.5, -10.0, -100.0)
            for n in -10:10
                n == 0 && continue
                check_pow(x, Float64(n))
            end
        end
    end

    @testset "integer y across `use_power_by_squaring` range" begin
        # Julia routes `yisint && use_power_by_squaring(yint)` through
        # `pow_body(::Float64, ::Integer)` (compensated power-by-squaring
        # with two_mul correction). |yint| ≤ 24576.
        for x in (1.001, 0.999, 1.5, 2.0, 0.5, -1.001, -1.5)
            for n in (1, 2, 3, 5, 10, 100, 500, 1000, 5000, 10000, 24576,
                      -1, -2, -3, -10, -100, -1000, -4096)
                check_pow(x, Float64(n))
            end
        end
    end

    # ── §13 MANDATORY: bivariate subnormal-output range ──────────────
    # Per the soft_exp post-mortem (Bennett-fnxg) and CLAUDE.md §13:
    # every transcendental must include a subnormal-output sweep,
    # because random sweeps over normal-output ranges miss this region.
    # Pow's high-risk region: inputs where y · log2(|x|) ∈ (-1075, -1022)
    # so the output lands at the smallest-normal/subnormal boundary.
    # Two axes (small-x × large-y AND near-1-x × huge-y) must both be
    # exhaustively swept — single-axis coverage missed comparable bug
    # classes in soft_exp (Bennett-wigl) and is the rejected-path A
    # rationale that motivates this contract.

    @testset "BIT-EXACT subnormal-output sweep — small x × large y vs Base.^" begin
        n_total = 0; n_pass = 0; max_diff = 0
        for x in (0.5, 0.25, 0.1, 0.01, 1e-5, 1e-10, 1e-100, 1e-200)
            log2x = log2(x)
            y_lo = -1022.0 / log2x
            y_hi = -1075.0 / log2x
            for k in 0:20
                y = y_lo + (y_hi - y_lo) * k / 20.0
                e = _pow_safe(x, y)
                isnan(e) && continue   # Julia threw — skip
                e_bits = bits(e)
                a_bits = soft_pow_julia(bits(x), bits(y))
                d = a_bits >= e_bits ? a_bits - e_bits : e_bits - a_bits
                n_total += 1
                a_bits == e_bits && (n_pass += 1)
                max_diff = max(max_diff, d)
            end
        end
        @test n_pass == n_total
        @test max_diff == 0
    end

    @testset "BIT-EXACT subnormal-output sweep — x near 1 × huge y vs Base.^" begin
        n_total = 0; n_pass = 0; max_diff = 0
        for k in 1:30, sign_eps in (1.0, -1.0)
            x = 1.0 + sign_eps * 2.0^(-k)
            x == 1.0 && continue
            log2x = log2(x); log2x == 0.0 && continue
            y_lo = -1022.0 / log2x
            y_hi = -1075.0 / log2x
            for frac in (0.0, 0.25, 0.5, 0.75, 1.0)
                y = y_lo + (y_hi - y_lo) * frac
                !isfinite(y) && continue
                e = _pow_safe(x, y)
                isnan(e) && continue
                e_bits = bits(e)
                a_bits = soft_pow_julia(bits(x), bits(y))
                d = a_bits >= e_bits ? a_bits - e_bits : e_bits - a_bits
                n_total += 1
                a_bits == e_bits && (n_pass += 1)
                max_diff = max(max_diff, d)
            end
        end
        @test n_pass == n_total
        @test max_diff == 0
    end

    # ── Random sweeps ────────────────────────────────────────────────

    @testset "BIT-EXACT random sweep (100 000 samples, full domain) vs Base.^" begin
        Random.seed!(0x4A45584F)   # "JEXO"
        n_total = 0; n_pass = 0; max_diff = 0
        for _ in 1:100_000
            x = exp((rand() - 0.5) * 100.0)
            y = (rand() - 0.5) * 50.0
            (x == 0.0 || !isfinite(x) || !isfinite(y)) && continue
            e = _pow_safe(x, y)
            isnan(e) && continue
            e_bits = bits(e)
            a_bits = soft_pow_julia(bits(x), bits(y))
            d = a_bits >= e_bits ? a_bits - e_bits : e_bits - a_bits
            n_total += 1
            a_bits == e_bits && (n_pass += 1)
            max_diff = max(max_diff, d)
        end
        @test n_pass == n_total
        @test max_diff == 0
    end

    @testset "BIT-EXACT extreme bivariate random sweep (5k samples) vs Base.^" begin
        Random.seed!(0xBEAD0001)
        n_total = 0; n_pass = 0; max_diff = 0
        for _ in 1:5_000
            x = exp((rand() - 0.5) * 1000.0)
            y = (rand() - 0.5) * 200.0
            (x == 0.0 || !isfinite(x) || !isfinite(y)) && continue
            e = _pow_safe(x, y)
            isnan(e) && continue
            e_bits = bits(e)
            a_bits = soft_pow_julia(bits(x), bits(y))
            d = a_bits >= e_bits ? a_bits - e_bits : e_bits - a_bits
            n_total += 1
            a_bits == e_bits && (n_pass += 1)
            max_diff = max(max_diff, d)
        end
        @test n_pass == n_total
        @test max_diff == 0
    end

    @testset "BIT-EXACT negative-x × random integer y sweep vs Base.^" begin
        Random.seed!(0xBEAD0002)
        n_total = 0; n_pass = 0; max_diff = 0
        for _ in 1:3_000
            x = -100.0 + 200.0 * rand()
            x == 0.0 && continue
            y = Float64(rand(-100:100))
            e = _pow_safe(x, y)
            isnan(e) && continue
            e_bits = bits(e)
            a_bits = soft_pow_julia(bits(x), bits(y))
            d = a_bits >= e_bits ? a_bits - e_bits : e_bits - a_bits
            n_total += 1
            a_bits == e_bits && (n_pass += 1)
            max_diff = max(max_diff, d)
        end
        @test n_pass == n_total
        @test max_diff == 0
    end

    @testset "overflow boundary sweep (y · log2(x) near 1024)" begin
        n_total = 0; n_pass = 0; max_diff = 0
        for x in (2.0, 3.0, 10.0, 1.5, 100.0)
            log2x = log2(x)
            for k in 1015:1030
                y = Float64(k) / log2x
                e = _pow_safe(x, y)
                isnan(e) && continue
                e_bits = bits(e)
                a_bits = soft_pow_julia(bits(x), bits(y))
                d = a_bits >= e_bits ? a_bits - e_bits : e_bits - a_bits
                n_total += 1
                a_bits == e_bits && (n_pass += 1)
                max_diff = max(max_diff, d)
            end
        end
        @test n_pass == n_total
        @test max_diff == 0
    end
end  # soft_pow_julia
