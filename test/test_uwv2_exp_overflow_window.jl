# Bennett-uwv2: exp-family NaN in the top overflow reduction cell.
#
# The musl/AOR-port kernels (`soft_exp`, `soft_exp2`, `soft_exp_fast`,
# `soft_exp2_fast`) build the scale factor as `sbits = T[2j+1] + (ki << 45)`.
# When x is in the upper half of the last reduction cell below overflow,
# ki rounds up to k = 1024 with j = 0, so `sbits` has biased exponent 0x7FF
# (+Inf) and `scale + scale·tmp` with tmp < 0 is `Inf - Inf = NaN`, even
# though the true result is finite. musl avoids this via the k > 0 arm of
# `specialcase()` (sbits -= 1009<<52, then ×2^1009), which the port omitted.
# Windows (from the Astra verification):
#   exp / expm1 / exp_fast: x ∈ [709.78000862, log(floatmax)]
#   exp2 / exp2_fast:       x ∈ [1023.99609, 1024)
#   sinh / cosh:            |x| ∈ [1419.5600, 1419.5654]  (huge arm exp(|x|/2))
# The fnxg subnormal-output sweep (rule 13) targets the underflow side and a
# 0.25-step sweep straddles these windows; this file is the overflow-side
# analogue: a ≤1e-6-step sweep of the final reduction cell plus bit-stepping
# down from the last finite-output input.
#
# Tolerances (from the docstrings / existing contract tests):
#   soft_exp, soft_exp2 (+ _fast): ≤1 ULP vs Base (bit-exact vs musl; the
#     ys0d contract pins ~0.9% 1-ULP disagreement with Base.exp).
#   soft_expm1, soft_sinh, soft_cosh: ≤2 ULP vs Base.
# In every case the result must be ±Inf exactly where Base gives ±Inf, and
# never NaN for a non-NaN input.

using Test
using Bennett

function _ulp_uwv2(got::Float64, ref::Float64)
    isnan(ref) && return isnan(got) ? 0 : typemax(Int64)
    isnan(got) && return typemax(Int64)
    ord(x) = (b = reinterpret(Int64, x); b < 0 ? typemin(Int64) - b : b)
    d = widen(ord(got)) - widen(ord(ref))
    return Int64(min(abs(d), widen(typemax(Int64))))
end

_call(sf, x::Float64) = reinterpret(Float64, sf(reinterpret(UInt64, x)))

# Returns (n_bad, n_nan, n_inf_mismatch, max_ulp_on_finite) over xs.
function _sweep_uwv2(sf, f, xs, tol)
    nbad = 0; nnan = 0; ninf = 0; maxu = 0
    for x in xs
        got = _call(sf, x); ref = f(x)
        isnan(got) && (nnan += 1)
        isinf(got) == isinf(ref) || (ninf += 1)
        u = _ulp_uwv2(got, ref)
        isfinite(ref) && (maxu = max(maxu, u))
        u <= tol || (nbad += 1)
    end
    return (nbad, nnan, ninf, maxu)
end

# Last N floats at and below `top` (bit-stepping downward).
_below(top::Float64, n::Int) = [reinterpret(Float64, reinterpret(UInt64, top) - UInt64(i)) for i in 0:n-1]

# log(floatmax) = 709.782712893384 (0x40862e42fefa39ef), the largest finite-output
# exp input. NB the literal `709.7827128933841` (Base.Math.MAX_EXP) is its
# nextfloat — the FIRST Inf-output input.
const _LOGMAX = reinterpret(Float64, 0x40862e42fefa39ef)
@assert isfinite(exp(_LOGMAX)) && isinf(exp(nextfloat(_LOGMAX)))

@testset "Bennett-uwv2: exp-family top overflow cell (no NaN, Inf where Base is Inf)" begin

    @testset "report witnesses" begin
        @test Bennett.soft_exp(0x40862e4189374bc7)  == reinterpret(UInt64, exp(reinterpret(Float64, 0x40862e4189374bc7)))
        @test Bennett.soft_exp(0x40862e42fefa39ef)  == reinterpret(UInt64, exp(reinterpret(Float64, 0x40862e42fefa39ef)))
        @test Bennett.soft_exp2(0x408ffff9db22d0e5) == reinterpret(UInt64, exp2(reinterpret(Float64, 0x408ffff9db22d0e5)))
        @test Bennett.soft_exp2(0x408fffffffffffff) == reinterpret(UInt64, exp2(prevfloat(1024.0)))
        @test _ulp_uwv2(_call(Bennett.soft_expm1, reinterpret(Float64, 0x40862e4189374bc7)),
                        expm1(reinterpret(Float64, 0x40862e4189374bc7))) <= 2
        for s in (1.0, -1.0)
            @test _call(Bennett.soft_sinh, s * 1419.564) === sinh(s * 1419.564)
        end
        @test _call(Bennett.soft_cosh, 1419.564) === Inf
    end

    # exp-type windows: step 1e-6 over the top cell + endpoints + 2000 floats
    # bit-stepped down from the last finite-output input + first Inf inputs.
    exp_xs  = vcat(collect(709.78:1e-6:709.7828), [709.78, 709.7828, _LOGMAX, nextfloat(_LOGMAX),
                   nextfloat(_LOGMAX, 2), 709.79, 710.0], _below(_LOGMAX, 2000))
    exp2_xs = vcat(collect(1023.99:1e-6:1024.0), [1023.99, prevfloat(1024.0), 1024.0,
                   nextfloat(1024.0), 1025.0], _below(prevfloat(1024.0), 2000))
    hyp_xs  = vcat(collect(1419.55:1e-6:1419.57), [1419.55, 1419.57, 2 * _LOGMAX,
                   nextfloat(2 * _LOGMAX), prevfloat(2 * _LOGMAX), 710.475, 710.476, 1500.0])

    for (name, sf, f, xs, tol) in (
            ("soft_exp",       Bennett.soft_exp,       exp,   exp_xs,  1),
            ("soft_exp_fast",  Bennett.soft_exp_fast,  exp,   exp_xs,  1),
            ("soft_expm1",     Bennett.soft_expm1,     expm1, exp_xs,  2),
            ("soft_exp2",      Bennett.soft_exp2,      exp2,  exp2_xs, 1),
            ("soft_exp2_fast", Bennett.soft_exp2_fast, exp2,  exp2_xs, 1),
            ("soft_sinh(+x)",  Bennett.soft_sinh,      sinh,  hyp_xs,  2),
            ("soft_sinh(-x)",  Bennett.soft_sinh,      sinh,  -hyp_xs, 2),
            ("soft_cosh(+x)",  Bennett.soft_cosh,      cosh,  hyp_xs,  2),
            ("soft_cosh(-x)",  Bennett.soft_cosh,      cosh,  -hyp_xs, 2))
        @testset "$name window sweep (n=$(length(xs)), ≤$tol ULP)" begin
            nbad, nnan, ninf, maxu = _sweep_uwv2(sf, f, xs, tol)
            @info "Bennett-uwv2 $name" n = length(xs) nbad nnan ninf max_ulp_finite = maxu
            @test nnan == 0
            @test ninf == 0
            @test nbad == 0
        end
    end
end
