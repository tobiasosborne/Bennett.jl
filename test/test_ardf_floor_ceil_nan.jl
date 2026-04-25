# Bennett-ardf / U138 — soft_floor / soft_ceil / soft_trunc were
# implemented but their NaN propagation was untested at the strict-bit
# level. Existing test_soft_fround.jl had `if isnan(expected)` /
# `@test isnan(result)` round-trip checks but not bit-exact agreement
# with Base.floor/ceil/trunc on specific NaN payloads.
#
# Verified 2026-04-26: soft_floor/ceil/trunc each bit-exactly match
# Julia's Base.floor/ceil/trunc on every NaN bit pattern tested,
# including:
#   - canonical qNaN
#   - canonical qNaN with the sign bit set (negative qNaN)
#   - qNaN with payload
#   - sNaN (gets quieted via soft_trunc → soft_fadd's NaN-canonicalise path)
#
# This file regression-anchors the bit-exact behaviour. Bennett-r84x /
# U08 already pins the underlying soft_fadd NaN-canonicalise pattern;
# this test confirms floor/ceil round-trip through the same machinery
# without breaking it.

using Test
using Bennett
using Bennett: soft_floor, soft_ceil, soft_trunc

# A representative NaN bit pattern set. Each is Float64 with the
# exponent all-1s and a non-zero mantissa.
const _ARDF_NAN_BITS = (
    0x7ff8000000000000,  # canonical qNaN, +
    0xfff8000000000000,  # canonical qNaN, -
    0x7ff8000000000001,  # qNaN with payload 1, +
    0xfff8000000000001,  # qNaN with payload 1, -
    0x7ff0000000000001,  # sNaN (quiet bit clear), payload 1, +
    0xfff0000000000001,  # sNaN, payload 1, -
    0x7ffabcdef1234567,  # qNaN with arbitrary payload, +
    0xfffabcdef1234567,  # qNaN with arbitrary payload, -
)

@testset "Bennett-ardf / U138 — soft_floor/ceil/trunc bit-exact NaN" begin

    @testset "soft_trunc(NaN) ≡ Base.trunc(NaN) bit-for-bit" begin
        for nan_bits in _ARDF_NAN_BITS
            nan = reinterpret(Float64, nan_bits)
            expected = reinterpret(UInt64, trunc(nan))
            actual   = soft_trunc(nan_bits)
            @test actual == expected
        end
    end

    @testset "soft_floor(NaN) ≡ Base.floor(NaN) bit-for-bit" begin
        for nan_bits in _ARDF_NAN_BITS
            nan = reinterpret(Float64, nan_bits)
            expected = reinterpret(UInt64, floor(nan))
            actual   = soft_floor(nan_bits)
            @test actual == expected
        end
    end

    @testset "soft_ceil(NaN) ≡ Base.ceil(NaN) bit-for-bit" begin
        for nan_bits in _ARDF_NAN_BITS
            nan = reinterpret(Float64, nan_bits)
            expected = reinterpret(UInt64, ceil(nan))
            actual   = soft_ceil(nan_bits)
            @test actual == expected
        end
    end

    @testset "result is a NaN per IEEE 754 (exp=all-1s, mantissa≠0)" begin
        for nan_bits in _ARDF_NAN_BITS, fn in (soft_floor, soft_ceil, soft_trunc)
            result = fn(nan_bits)
            exp_bits = (result >> 52) & 0x7ff
            mantissa = result & UInt64(0x000fffffffffffff)
            @test exp_bits == 0x7ff
            @test mantissa != 0
        end
    end

    @testset "fdiv overflow_result discard regression guard" begin
        # Bennett-ardf / U138: fdiv.jl line 82 used to bind
        # `_overflow_result` and never reference it. Now uses `_`.
        # Guards the dead binding from being reintroduced (would
        # fail clippy-style style checks if Julia had them).
        path = joinpath(dirname(pathof(Bennett)),
                        "softfloat", "fdiv.jl")
        src = read(path, String)
        @test !occursin("_overflow_result", src)
    end
end
