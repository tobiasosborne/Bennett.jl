# Bennett-lx5h: float vector reductions — the float follow-up to Bennett-pg5.
# Covers all 8 LLVM float-vector-reduction intrinsics:
#   - llvm.vector.reduce.fadd.v<N>f64       (NaN-propagating, scalar START arg)
#   - llvm.vector.reduce.fmul.v<N>f64       (NaN-propagating, scalar START arg)
#   - llvm.vector.reduce.fmin.v<N>f64       (NaN-absorbing, ≡ minNum)
#   - llvm.vector.reduce.fmax.v<N>f64       (NaN-absorbing, ≡ maxNum)
#   - llvm.vector.reduce.fminimum.v<N>f64   (NaN-propagating, IEEE 2008)
#   - llvm.vector.reduce.fmaximum.v<N>f64   (NaN-propagating, IEEE 2008)
#   - llvm.vector.reduce.fminimumnum.v<N>f64 (NaN-absorbing, IEEE 2019)
#   - llvm.vector.reduce.fmaximumnum.v<N>f64 (NaN-absorbing, IEEE 2019)
#
# Strict left-to-right fold (no `reassoc` exploitation) per CLAUDE.md §13;
# bit-exact against a reference fold over the matching soft_* primitive.
# f32 vector forms rejected per §13 / Bennett-3rph.

using Test
using Bennett

const LX5H_LL = joinpath(@__DIR__, "fixtures", "ll")

@inline _bits(x::Float64) = reinterpret(UInt64, x)
@inline _flt(x::UInt64)   = reinterpret(Float64, x)

function lx5h_compile(entry::AbstractString, file::AbstractString)
    parsed = Bennett.extract_parsed_ir_from_ll(joinpath(LX5H_LL, file);
                                               entry_function=entry)
    circuit = reversible_compile(parsed)
    @test verify_reversibility(circuit)
    return circuit
end

function lx5h_reject(file::AbstractString, entry::AbstractString)
    err = try
        Bennett.extract_parsed_ir_from_ll(joinpath(LX5H_LL, file);
                                          entry_function=entry)
        nothing
    catch e
        sprint(showerror, e)
    end
    return err
end

# Reference fold helpers — bit-exact against the soft_* IRCall chain that
# the dispatch arm should emit. These are the source-of-truth oracles;
# Base.+ / Base.* would produce the same answer for finite NaN-free inputs
# but diverge under NaN propagation in subtle ways for fadd/fmul.

function _ref_fadd_fold(start::Float64, lanes::Vector{Float64})::Float64
    acc = _bits(start)
    for x in lanes
        acc = Bennett.soft_fadd(acc, _bits(x))
    end
    return _flt(acc)
end

function _ref_fmul_fold(start::Float64, lanes::Vector{Float64})::Float64
    acc = _bits(start)
    for x in lanes
        acc = Bennett.soft_fmul(acc, _bits(x))
    end
    return _flt(acc)
end

# NaN-absorbing min/max reference (≡ llvm.minnum / soft_fmin / minimumNumber).
function _ref_minNum(a::Float64, b::Float64)::Float64
    isnan(a) && isnan(b) && return NaN
    isnan(a) && return b
    isnan(b) && return a
    if a == 0.0 && b == 0.0
        return signbit(a) ? a : b
    end
    return a < b ? a : b
end

function _ref_maxNum(a::Float64, b::Float64)::Float64
    isnan(a) && isnan(b) && return NaN
    isnan(a) && return b
    isnan(b) && return a
    if a == 0.0 && b == 0.0
        return signbit(a) ? b : a
    end
    return a > b ? a : b
end

# Reduction wrappers — left-to-right fold over the chosen pairwise op.
function _ref_min_fold(lanes::Vector{Float64}, ::Val{:absorb})
    acc = lanes[1]
    for i in 2:length(lanes)
        acc = _ref_minNum(acc, lanes[i])
    end
    return acc
end

function _ref_max_fold(lanes::Vector{Float64}, ::Val{:absorb})
    acc = lanes[1]
    for i in 2:length(lanes)
        acc = _ref_maxNum(acc, lanes[i])
    end
    return acc
end

# Base.min / Base.max are NaN-propagating (≡ IEEE 754-2008 minimum/maximum).
function _ref_min_fold(lanes::Vector{Float64}, ::Val{:propagate})
    acc = lanes[1]
    for i in 2:length(lanes)
        acc = min(acc, lanes[i])
    end
    return acc
end

function _ref_max_fold(lanes::Vector{Float64}, ::Val{:propagate})
    acc = lanes[1]
    for i in 2:length(lanes)
        acc = max(acc, lanes[i])
    end
    return acc
end

@testset "Bennett-lx5h: llvm.vector.reduce.{fadd,fmul,fmin,fmax,fminimum,fmaximum,fminimumnum,fmaximumnum}" begin

    # ---- fadd / fmul (scalar START arg) ----

    @testset "reduce.fadd.v4f64 — start + sum (identity AND non-identity start)" begin
        c = lx5h_compile("lx5h_reduce_fadd_v4f64", "lx5h_reduce_fadd_v4f64.ll")
        # Identity start = -0.0 → result is just sum(lanes) (per LLVM langref).
        # Non-identity start = 7.5 → result includes the start.
        cases = ((-0.0, [1.0, 2.0, 3.0, 4.0]),                  # start = -0.0; pure sum = 10.0
                 (7.5,  [1.0, 2.0, 3.0, 4.0]),                  # non-identity start; result = 17.5
                 (-0.0, [1e16, 1.0, -1e16, 1.0]),               # cancellation order matters
                 (0.0,  [Inf, -Inf, 1.0, 2.0]),                 # Inf - Inf = NaN propagates
                 (-0.0, [NaN, 1.0, 2.0, 3.0]),                  # NaN propagates
                 (1.0,  [-1.0, 0.0, -0.0, 0.0]))                # ±0 sign at end
        for (start, lanes) in cases
            expected = _ref_fadd_fold(start, lanes)
            got = _flt(simulate(c, (_bits(start), _bits(lanes[1]),
                                    _bits(lanes[2]), _bits(lanes[3]),
                                    _bits(lanes[4]))))
            @test _bits(got) == _bits(expected)
        end
    end

    @testset "reduce.fadd.v2f64 — single fold step (smallest non-trivial width)" begin
        c = lx5h_compile("lx5h_reduce_fadd_v2f64", "lx5h_reduce_fadd_v2f64.ll")
        cases = ((-0.0, [1.0, 2.0]),
                 (7.5,  [1.0, 2.0]),
                 (-0.0, [Inf, -Inf]))   # Inf + -Inf = NaN
        for (start, lanes) in cases
            expected = _ref_fadd_fold(start, lanes)
            got = _flt(simulate(c, (_bits(start), _bits(lanes[1]), _bits(lanes[2]))))
            @test _bits(got) == _bits(expected)
        end
    end

    @testset "reduce.fmul.v4f64 — start * prod (identity AND non-identity start)" begin
        c = lx5h_compile("lx5h_reduce_fmul_v4f64", "lx5h_reduce_fmul_v4f64.ll")
        cases = ((1.0,  [2.0, 3.0, 4.0, 5.0]),                  # identity start = 1.0; product = 120.0
                 (2.5,  [2.0, 4.0, 0.5, 1.0]),                  # non-identity start; result = 10.0
                 (1.0,  [-1.0, 2.0, -3.0, 4.0]),                # signs
                 (1.0,  [0.0, 1e308, 1e308, 1e308]),            # 0 * Inf = NaN propagates (after overflow)
                 (1.0,  [NaN, 2.0, 3.0, 4.0]))                  # NaN propagates
        for (start, lanes) in cases
            expected = _ref_fmul_fold(start, lanes)
            got = _flt(simulate(c, (_bits(start), _bits(lanes[1]),
                                    _bits(lanes[2]), _bits(lanes[3]),
                                    _bits(lanes[4]))))
            @test _bits(got) == _bits(expected)
        end
    end

    # ---- fmin / fmax (NaN-absorbing) ----

    @testset "reduce.fmin.v4f64 (NaN-absorbing) — ordered + NaN + ±0/±Inf" begin
        c = lx5h_compile("lx5h_reduce_fmin_v4f64", "lx5h_reduce_fmin_v4f64.ll")
        cases = ([1.0, -2.0, 3.0, -4.0],
                 [-100.0, -50.0, -1.0, -200.0],
                 [NaN, 1.0, 2.0, 3.0],            # NaN-absorbing → returns 1.0
                 [1.0, NaN, 2.0, 3.0],            # interior NaN absorbed
                 [NaN, NaN, NaN, NaN],            # all-NaN → NaN
                 [Inf, -Inf, 1.0, 0.0],
                 [0.0, -0.0, 0.0, 0.0],           # ±0 tie → -0
                 [-0.0, 0.0, -0.0, 0.0])
        for lanes in cases
            expected = _ref_min_fold(lanes, Val(:absorb))
            got = _flt(simulate(c, (_bits(lanes[1]), _bits(lanes[2]),
                                    _bits(lanes[3]), _bits(lanes[4]))))
            @test _bits(got) == _bits(expected)
        end
    end

    @testset "reduce.fmax.v4f64 (NaN-absorbing) — ordered + NaN + ±0/±Inf" begin
        c = lx5h_compile("lx5h_reduce_fmax_v4f64", "lx5h_reduce_fmax_v4f64.ll")
        cases = ([1.0, -2.0, 3.0, -4.0],
                 [100.0, 50.0, 1.0, 200.0],
                 [NaN, 1.0, 2.0, 3.0],
                 [1.0, NaN, 2.0, 3.0],
                 [NaN, NaN, NaN, NaN],
                 [Inf, -Inf, 1.0, 0.0],
                 [0.0, -0.0, 0.0, 0.0],           # ±0 tie → +0
                 [-0.0, 0.0, -0.0, 0.0])
        for lanes in cases
            expected = _ref_max_fold(lanes, Val(:absorb))
            got = _flt(simulate(c, (_bits(lanes[1]), _bits(lanes[2]),
                                    _bits(lanes[3]), _bits(lanes[4]))))
            @test _bits(got) == _bits(expected)
        end
    end

    # ---- fminimum / fmaximum (NaN-propagating, IEEE 754-2008) ----

    @testset "reduce.fminimum.v4f64 (NaN-propagating) — Base.min fold" begin
        c = lx5h_compile("lx5h_reduce_fminimum_v4f64", "lx5h_reduce_fminimum_v4f64.ll")
        cases = ([1.0, -2.0, 3.0, -4.0],
                 [-100.0, -50.0, -1.0, -200.0],
                 [NaN, 1.0, 2.0, 3.0],            # NaN-propagating → returns NaN
                 [1.0, 2.0, NaN, 3.0],
                 [NaN, NaN, NaN, NaN],
                 [Inf, -Inf, 1.0, 0.0],
                 [0.0, -0.0, 0.0, 0.0],
                 [-0.0, 0.0, -0.0, 0.0])
        for lanes in cases
            expected = _ref_min_fold(lanes, Val(:propagate))
            got = _flt(simulate(c, (_bits(lanes[1]), _bits(lanes[2]),
                                    _bits(lanes[3]), _bits(lanes[4]))))
            @test _bits(got) == _bits(expected)
        end
    end

    @testset "reduce.fmaximum.v4f64 (NaN-propagating) — Base.max fold" begin
        c = lx5h_compile("lx5h_reduce_fmaximum_v4f64", "lx5h_reduce_fmaximum_v4f64.ll")
        cases = ([1.0, -2.0, 3.0, -4.0],
                 [100.0, 50.0, 1.0, 200.0],
                 [NaN, 1.0, 2.0, 3.0],
                 [1.0, 2.0, NaN, 3.0],
                 [NaN, NaN, NaN, NaN],
                 [Inf, -Inf, 1.0, 0.0],
                 [0.0, -0.0, 0.0, 0.0],
                 [-0.0, 0.0, -0.0, 0.0])
        for lanes in cases
            expected = _ref_max_fold(lanes, Val(:propagate))
            got = _flt(simulate(c, (_bits(lanes[1]), _bits(lanes[2]),
                                    _bits(lanes[3]), _bits(lanes[4]))))
            @test _bits(got) == _bits(expected)
        end
    end

    # ---- fminimumnum / fmaximumnum (NaN-absorbing, IEEE 754-2019) ----
    # Bit-identical to fmin/fmax (soft_minimumnum / soft_maximumnum are
    # aliases per Bennett-p19b), but verified through their own IR path.

    @testset "reduce.fminimumnum.v4f64 (IEEE 2019, NaN-absorbing)" begin
        c = lx5h_compile("lx5h_reduce_fminimumnum_v4f64",
                         "lx5h_reduce_fminimumnum_v4f64.ll")
        cases = ([1.0, -2.0, 3.0, -4.0],
                 [NaN, 1.0, 2.0, 3.0],            # NaN-absorbing
                 [1.0, NaN, NaN, 3.0],
                 [NaN, NaN, NaN, NaN],
                 [Inf, -Inf, 1.0, 0.0],
                 [0.0, -0.0, 0.0, 0.0])
        for lanes in cases
            expected = _ref_min_fold(lanes, Val(:absorb))
            got = _flt(simulate(c, (_bits(lanes[1]), _bits(lanes[2]),
                                    _bits(lanes[3]), _bits(lanes[4]))))
            @test _bits(got) == _bits(expected)
        end
    end

    @testset "reduce.fmaximumnum.v4f64 (IEEE 2019, NaN-absorbing)" begin
        c = lx5h_compile("lx5h_reduce_fmaximumnum_v4f64",
                         "lx5h_reduce_fmaximumnum_v4f64.ll")
        cases = ([1.0, -2.0, 3.0, -4.0],
                 [NaN, 1.0, 2.0, 3.0],
                 [1.0, NaN, NaN, 3.0],
                 [NaN, NaN, NaN, NaN],
                 [Inf, -Inf, 1.0, 0.0],
                 [0.0, -0.0, 0.0, 0.0])
        for lanes in cases
            expected = _ref_max_fold(lanes, Val(:absorb))
            got = _flt(simulate(c, (_bits(lanes[1]), _bits(lanes[2]),
                                    _bits(lanes[3]), _bits(lanes[4]))))
            @test _bits(got) == _bits(expected)
        end
    end

    # ---- f32 rejection per CLAUDE.md §13 / Bennett-3rph ----

    @testset "f32 vector-reduction forms rejected (CLAUDE.md §13)" begin
        for (file, entry) in (("lx5h_reduce_fadd_v4f32_reject.ll", "lx5h_reduce_fadd_v4f32"),
                              ("lx5h_reduce_fmin_v4f32_reject.ll", "lx5h_reduce_fmin_v4f32"))
            err = lx5h_reject(file, entry)
            @test err !== nothing
            # Must mention f64-only / Bennett-lx5h / §13 context.
            @test occursin("f64", err) || occursin("Bennett-lx5h", err) ||
                  occursin("CLAUDE.md", err) || occursin("Bennett-3rph", err)
        end
    end
end
