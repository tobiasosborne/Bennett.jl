using Test, Bennett
using Bennett: soft_pow_julia

# Bennett-bie9: `soft_pow_julia` (bit-exact port of Base.:^(::Float64,
# ::Float64)) must extract and compile. Its integer-y body
# `_pj_pow_body_int` used to be a data-dependent `while n > 1` loop that
# LLVM left out of line as `j__pj_pow_body_int_*`, an unregistered callee.
#
# Invariant: `_pj_pow_body_int` is straight-line (fixed 14-step, branchless
# squaring, inlined), so `soft_pow_julia`'s IR has no call to any helper
# outside the callee registry (extraction succeeds), and the port stays
# bit-exact vs Base.:^ for every integer exponent in the squaring range.

_bie9_pow_safe(x::Float64, y::Float64) = try x^y catch; NaN end
_bie9_bits(x::Float64) = reinterpret(UInt64, x)

function _bie9_same(got::UInt64, x::Float64, y::Float64)
    e = _bie9_pow_safe(x, y)
    isnan(e) ? isnan(reinterpret(Float64, got)) : got == _bie9_bits(e)
end

@testset "Bennett-bie9: soft_pow_julia extracts" begin

    @testset "integer-y body: every iteration count, bit-exact vs Base.:^" begin
        # Every n in Base's power-by-squaring range [-4096, 24576] exercises a
        # distinct (iteration count, odd-bit pattern) of the fixed-step body.
        bad = Tuple{Float64,Int}[]
        for x in (1.0000001, 0.9999999, -1.3, 2.5, 0.7, 1.0e-3, 3.0e5, 5.0e-324, -Inf, NaN)
            for n in -4096:24576
                y = Float64(n)
                _bie9_same(soft_pow_julia(_bie9_bits(x), _bie9_bits(y)), x, y) ||
                    push!(bad, (x, n))
            end
        end
        @test isempty(bad)
    end

    @testset "extract: no unregistered helper call remains" begin
        pir = Bennett.extract_parsed_ir(soft_pow_julia, Tuple{UInt64, UInt64})
        @test pir isa Bennett.ParsedIR
    end

    # The compile test is test/test_bie9_pow_julia_compile.jl. (Before the
    # adder/multiplier `sizehint!` shrink fix, `reversible_compile(^, Float64,
    # Float64; max_loop_iterations = 64)` did not finish in 25 min: lowering
    # copied the whole gate vector on every add / multiply.)
end
